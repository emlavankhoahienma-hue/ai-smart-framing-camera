import SwiftUI
import UIKit

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode
    
    @State private var geminiKeyInput: String = ""
    @State private var showKeyInput: Bool = false
    @State private var isKeyVisible: Bool = false
    @State private var keySavedMessage: String? = nil
    @State private var selectedModel: AIVisionModel = .autoStrongest
    @State private var customModelInput: String = ""
    @State private var isTestingKey: Bool = false
    @State private var testResult: String? = nil
    @State private var showDevConsole: Bool = false
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - 1. Developer Profile (VanKhoa)
                Section(header: Text("👨‍💻 THÔNG TIN DEVELOPER")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "person.crop.circle.fill.badge.checkmark")
                                .font(.system(size: 28))
                                .foregroundColor(.cyan)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("VanKhoa")
                                    .font(.headline.bold())
                                    .foregroundColor(.white)
                                Text("iOS & AI Camera Engineer")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        
                        Divider().background(Color.gray.opacity(0.3))
                        
                        HStack {
                            Label("Email:", systemImage: "envelope.fill")
                                .font(.caption.bold())
                                .foregroundColor(.yellow)
                            Spacer()
                            Text("tranvantrinhhd@gmail.com")
                                .font(.caption.monospaced())
                                .foregroundColor(.white)
                        }
                        
                        HStack {
                            Label("Hotline:", systemImage: "phone.fill")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                            Spacer()
                            Text("+84 344197212")
                                .font(.caption.bold().monospaced())
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: - 2. Gemini AI Key & Connection
                Section(header: Text("🔑 CẤU HÌNH GOOGLE GEMINI API")) {
                    // Status row
                    HStack {
                        Label("Trạng thái", systemImage: "key.horizontal.fill")
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Đã sẵn sàng").font(.subheadline.bold()).foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("Chưa có Key").font(.subheadline.bold()).foregroundColor(.red)
                            }
                        }
                    }
                    
                    // Quick Action: Paste & Test Buttons
                    HStack(spacing: 10) {
                        Button(action: {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                geminiKeyInput = clip
                                viewModel.geminiService.apiKey = clip
                                keySavedMessage = "✅ Đã dán Key thành công!"
                                testResult = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { keySavedMessage = nil }
                            } else {
                                keySavedMessage = "⚠️ Clipboard không có văn bản"
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.clipboard.fill")
                                Text("Dán Key")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        
                        Button(action: {
                            isTestingKey = true
                            testResult = nil
                            viewModel.geminiService.testAPIKey { success, message in
                                isTestingKey = false
                                testResult = message
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isTestingKey {
                                    ProgressView().scaleEffect(0.7).padding(.trailing, 2)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                }
                                Text(isTestingKey ? "Đang thử..." : "Test Kết Nối")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.purple.opacity(0.2))
                            .foregroundColor(.purple)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 2)
                    
                    if let res = testResult {
                        Text(res)
                            .font(.caption2.bold())
                            .foregroundColor(res.contains("✅") ? .green : .red)
                            .lineLimit(3)
                    }
                    
                    if let saved = keySavedMessage {
                        Text(saved)
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                    }
                    
                    // Input Key Accordion
                    DisclosureGroup("Xem / Nhập Key thủ công", isExpanded: $showKeyInput) {
                        VStack(spacing: 8) {
                            HStack {
                                if isKeyVisible {
                                    TextField("AIzaSy...", text: $geminiKeyInput)
                                        .font(.caption.monospaced())
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                } else {
                                    SecureField("AIzaSy...", text: $geminiKeyInput)
                                        .font(.caption.monospaced())
                                }
                                
                                Button(action: { isKeyVisible.toggle() }) {
                                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                            
                            Button("Lưu Key") {
                                viewModel.geminiService.apiKey = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                keySavedMessage = "✅ Đã lưu!"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { keySavedMessage = nil }
                            }
                            .font(.caption.bold())
                            .foregroundColor(.green)
                        }
                        .padding(.top, 4)
                    }
                }
                
                // MARK: - 3. Model AI & Auto-Fallback Engine
                Section(header: Text("🤖 CHỌN MÔ HÌNH & TỰ ĐỘNG LUÂN CHUYỂN")) {
                    Picker("Mô hình AI", selection: $selectedModel) {
                        ForEach(AIVisionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { newModel in
                        viewModel.geminiService.selectedModel = newModel
                    }
                    
                    HStack {
                        Label("Chỉ định Model ID:", systemImage: "cpu")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Spacer()
                        TextField("Tự động", text: $customModelInput)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: customModelInput) { newVal in
                                viewModel.geminiService.customModelName = newVal
                            }
                    }
                    
                    Text("💡 Tính năng tự động: Khi 1 model bị hết Quota (429) hoặc lỗi, app sẽ tự động chuyển sang model tiếp theo ngay lập tức.")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }
                
                // MARK: - 4. Framing, Auto-Zoom & Color Science
                Section(header: Text("🎯 TÙY CHỈNH CHỤP & BÁM MỤC TIÊU")) {
                    Picker("Quy tắc bố cục", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }.tag(rule)
                        }
                    }
                    
                    Picker("Độ nhạy bám mục tiêu (Tracking)", selection: $viewModel.trackingSensitivity) {
                        ForEach(TrackingSensitivityPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    
                    Toggle("Tự động Zoom theo AI (Auto-Zoom)", isOn: $viewModel.isAutoZoomEnabled)
                    Toggle("Màu Leica / Hasselblad Natural", isOn: $viewModel.isAIFullColorEnabled)
                    Toggle("Không gian 3D ARKit", isOn: $viewModel.isARModeEnabled)
                }
                
                // MARK: - 5. Developer Debug Console (Collapsible)
                Section(header: Text("🛠 NHẬT KÝ & DEV CONSOLE")) {
                    DisclosureGroup("Xem nhật ký & lỗi", isExpanded: $showDevConsole) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Model đang active:")
                                Spacer()
                                Text(viewModel.activeModelUsedName.isEmpty ? "Chưa kích hoạt" : viewModel.activeModelUsedName)
                                    .font(.caption.bold().monospaced())
                                    .foregroundColor(.yellow)
                            }
                            
                            HStack {
                                Text("Độ trễ phản hồi:")
                                Spacer()
                                Text(viewModel.geminiLatencyMs > 0 ? "\(viewModel.geminiLatencyMs) ms" : "0 ms")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.cyan)
                            }
                            
                            if let err = viewModel.geminiError {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Lỗi gần nhất:").font(.caption.bold()).foregroundColor(.red)
                                    Text(err)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.red.opacity(0.85))
                                }
                                .padding(6)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - 6. Hardware & App Info
                Section(header: Text("ℹ️ THÔNG TIN PHẦN CỨNG")) {
                    hardwareRow("Kiến trúc", "CPU + Neural Engine + Metal GPU + Gemini Cloud", color: .yellow)
                    hardwareRow("Thiết bị hỗ trợ", "Apple A11 đến A18 Pro Bionic")
                    HStack { Text("Ứng dụng"); Spacer(); Text("VanKhoa AI Cam v2.5").font(.caption.bold()).foregroundColor(.white) }
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
