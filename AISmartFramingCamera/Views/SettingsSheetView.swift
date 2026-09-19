import SwiftUI
import UIKit

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AlignAI Studio").font(.title3.weight(.semibold))
                            Text("Tùy chỉnh theo cách bạn chụp").font(.subheadline).foregroundColor(.secondary)
                        }
                    } icon: { Image(systemName: "camera.aperture").font(.title).foregroundColor(CameraUI.accent) }
                    .padding(.vertical, 8)
                }
                Section("Máy ảnh") {
                    NavigationLink { CapturePreferences(viewModel: viewModel) } label: { Label("Ảnh & Video", systemImage: "camera") }
                    NavigationLink { ViewfinderPreferences(viewModel: viewModel) } label: { Label("Khung ngắm", systemImage: "viewfinder") }
                }
                Section("Trợ giúp sáng tạo") {
                    NavigationLink { FramingPreferences(viewModel: viewModel) } label: { Label("Bố cục AI", systemImage: "sparkles") }
                    NavigationLink { CloudPreferences(viewModel: viewModel) } label: { Label("Kết nối AI", systemImage: "cloud") }
                }
                Section("Ứng dụng") {
                    Toggle("Giữ màn hình sáng", isOn: $viewModel.isKeepScreenAwakeEnabled)
                    Toggle("Phản hồi rung khi căn khung", isOn: $viewModel.isProximityHapticsEnabled)
                    NavigationLink { CameraDiagnostics(viewModel: viewModel) } label: { Label("Thông tin & Chẩn đoán", systemImage: "info.circle") }
                    NavigationLink { FeedbackView() } label: { Label("Góp ý & Hỗ trợ", systemImage: "bubble.left") }
                    NavigationLink { SupportDeveloperView() } label: { Label("Ủng hộ tác giả", systemImage: "cup.and.saucer") }
                }
            }
            .navigationTitle("Cài đặt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }.tint(CameraUI.accent).preferredColorScheme(.dark)
    }
}

private struct CapturePreferences: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        Form {
            Section("Ảnh") {
                Picker("Định dạng", selection: $viewModel.selectedPhotoFormat) {
                    ForEach(PhotoSaveFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Live Photo", isOn: $viewModel.isLivePhotoEnabled)
                Toggle("Lưu thêm ảnh gốc", isOn: $viewModel.isSaveOriginalPhotoEnabled)
            }
            Section("Video") {
                Picker("Độ phân giải & tốc độ", selection: $viewModel.selectedVideoFormatOption) {
                    ForEach(VideoFormatOption.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Codec", selection: $viewModel.selectedVideoCodec) {
                    ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                }
            }.disabled(viewModel.isRecordingVideo)
            Section("Màu sắc") {
                Picker("Màu film", selection: Binding(get: { viewModel.selectedFilmPreset }, set: { viewModel.selectPreset($0) })) {
                    ForEach(FilmPreset.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("AI tự điều chỉnh màu", isOn: Binding(get: { viewModel.isAIFullColorEnabled }, set: { value in
                    if value != viewModel.isAIFullColorEnabled { viewModel.toggleAIFullColor() }
                }))
            }
        }.navigationTitle("Ảnh & Video").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ViewfinderPreferences: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        Form {
            Section("Hiển thị") {
                Toggle("Thước cân bằng", isOn: $viewModel.isHorizonLevelerEnabled)
                Toggle("Thông số phơi sáng & histogram", isOn: $viewModel.showHistogramInViewfinder)
                Toggle("Hiện biểu đồ màu", isOn: $viewModel.isHistogramBarExpanded)
                Toggle("Khung nhận diện chủ thể", isOn: $viewModel.showDetectionBoxes)
            }
            Section {
                Toggle("Tô viền vùng nét", isOn: $viewModel.isFocusPeakingEnabled)
                Picker("Màu viền", selection: $viewModel.focusPeakingColor) {
                    ForEach(FocusPeakingColor.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: { Text("Hỗ trợ lấy nét") } footer: {
                Text("Chạm để lấy nét. Giữ để khóa sáng và nét. Chụm hai ngón để thu phóng.")
            }
        }.navigationTitle("Khung ngắm").navigationBarTitleDisplayMode(.inline)
    }
}

private struct FramingPreferences: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        Form {
            Section("Bố cục") {
                Picker("Quy tắc", selection: Binding(get: { viewModel.activeCompositionRule }, set: { viewModel.selectRule($0) })) {
                    ForEach(CompositionRule.allCases) { Text($0.displayNameVietnamese).tag($0) }
                }
                Toggle("Tự chụp khi căn khớp", isOn: $viewModel.isAutoCaptureOnAlignEnabled)
                Toggle("Tự thu phóng", isOn: $viewModel.isAutoZoomEnabled)
                Toggle("Đường hướng dẫn về tâm", isOn: $viewModel.isGuidanceRayEnabled)
            }
            Section("Theo dõi chủ thể") {
                Picker("Độ nhạy", selection: $viewModel.trackingSensitivity) {
                    ForEach(TrackingSensitivityPreset.allCases) { Text($0.shortName).tag($0) }
                }
                Toggle("Chế độ đường phố", isOn: $viewModel.isStreetTrackingModeEnabled)
            }
        }.navigationTitle("Bố cục AI").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CloudPreferences: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var key = ""
    @State private var model = AIVisionModel.autoStrongest
    @State private var customModel = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var result: String?
    @State private var deleteKey = false
    var body: some View {
        Form {
            Section {
                Toggle("Dùng AI đám mây", isOn: $viewModel.useGeminiForAnalysis)
                Text("Khi có kết nối và khóa API, ứng dụng có thể gửi khung hình tới nhà cung cấp AI để đề xuất bố cục và màu sắc.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("Khóa API") {
                Label(hasKey ? "Đã lưu khóa" : "Chưa có khóa", systemImage: hasKey ? "checkmark.shield" : "key")
                SecureField("Nhập khóa API mới", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Lưu khóa") {
                    viewModel.geminiService.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    key = ""; hasKey = viewModel.geminiService.hasAPIKey; result = "Đã lưu khóa API."
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testing ? "Đang kiểm tra…" : "Kiểm tra kết nối") {
                    testing = true
                    Task {
                        let (_, message) = await viewModel.geminiService.testAPIKey()
                        result = message; testing = false
                    }
                }.disabled(!hasKey || testing)
                if hasKey { Button("Xóa khóa", role: .destructive) { deleteKey = true } }
                if let result { Text(result).font(.footnote).foregroundColor(.secondary).textSelection(.enabled) }
            }
            Section("Mô hình") {
                Picker("Mô hình AI", selection: $model) {
                    ForEach(AIVisionModel.allCases) { Text($0.displayName).tag($0) }
                }.onChange(of: model) { viewModel.geminiService.selectedModel = $0 }
                DisclosureGroup("Mô hình tùy chỉnh") {
                    TextField("ID mô hình", text: $customModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Lưu mô hình") { viewModel.geminiService.customModelName = customModel.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }.navigationTitle("Kết nối AI").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasKey = viewModel.geminiService.hasAPIKey
            model = viewModel.geminiService.selectedModel
            customModel = viewModel.geminiService.customModelName
        }
        .confirmationDialog("Xóa khóa API đã lưu?", isPresented: $deleteKey, titleVisibility: .visible) {
            Button("Xóa khóa", role: .destructive) { viewModel.geminiService.apiKey = ""; hasKey = false; result = nil }
        }
    }
}

private struct CameraDiagnostics: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var showLog = false
    @State private var reset = false
    var body: some View {
        Form {
            Section("AlignAI Studio") {
                LabeledContent("Phiên bản", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Bản dựng", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                LabeledContent("Tác giả", value: "VanKhoa (Trần Văn Trình)")
            }
            Section("Phiên hiện tại") {
                LabeledContent("Mô hình", value: viewModel.activeModelUsedName.isEmpty ? "Trên thiết bị" : viewModel.activeModelUsedName)
                LabeledContent("Độ trễ phân tích", value: "\(viewModel.geminiLatencyMs) ms")
                if let error = viewModel.geminiError { Text(error).font(.footnote).foregroundColor(.orange) }
                if let error = viewModel.videoDirectorError { Text(error).font(.footnote).foregroundColor(.orange) }
                Button("Xem nhật ký") { showLog = true }
                Button("Dừng phiên căn bố cục", role: .destructive) { reset = true }
            }
        }.navigationTitle("Thông tin & Chẩn đoán").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Dừng phiên căn bố cục hiện tại?", isPresented: $reset, titleVisibility: .visible) {
            Button("Dừng phiên", role: .destructive) { viewModel.cancelAISession() }
        }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView { Text(CameraLogger.readRecentLogText()).font(.caption.monospaced()).textSelection(.enabled).padding() }
                    .navigationTitle("Nhật ký")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { showLog = false } } }
            }
        }
    }
}

public struct SupportDeveloperView: View {
    @State private var copied = false
    public init() {}
    public var body: some View {
        Form {
            Section {
                Text("Cảm ơn bạn đã đồng hành cùng AlignAI.").font(.headline)
                Text("Nếu ứng dụng hữu ích, bạn có thể ủng hộ tác giả phát triển các tính năng mới.").foregroundColor(.secondary)
            }
            Section("Thông tin chuyển khoản") {
                LabeledContent("Ngân hàng", value: "MB Bank")
                LabeledContent("Chủ tài khoản", value: "TRAN VAN TRINH")
                LabeledContent("Số tài khoản", value: "0344197212")
                Button(copied ? "Đã sao chép" : "Sao chép số tài khoản") { UIPasteboard.general.string = "0344197212"; copied = true }
            }
            Section {
                DisclosureGroup("Mã VietQR · 50.000đ") {
                    AsyncImage(url: URL(string: "https://img.vietqr.io/image/mbbank-0344197212-compact2.png?amount=50000&addInfo=Donate%20AlignAI%20Camera&accountName=TRAN%20VAN%20TRINH")) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        case .failure: Text("Không tải được mã QR. Bạn có thể dùng số tài khoản ở trên.")
                        default: ProgressView().frame(maxWidth: .infinity)
                        }
                    }.frame(maxHeight: 320)
                }
            }
        }.navigationTitle("Ủng hộ tác giả").navigationBarTitleDisplayMode(.inline)
    }
}

struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
