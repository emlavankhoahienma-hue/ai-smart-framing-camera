import SwiftUI
import MessageUI
import PhotosUI

// MARK: - Feedback Category
public enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug = "Báo lỗi"
    case feature = "Đề xuất tính năng"
    case other = "Góp ý khác"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .bug: return "exclamationmark.triangle.fill"
        case .feature: return "sparkles"
        case .other: return "bubble.left.and.bubble.right.fill"
        }
    }
}

public struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: FeedbackCategory = .bug
    @State private var feedbackText: String = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedImagesData: [Data] = []
    @State private var showMailComposer = false
    @State private var showNoMailAlert = false
    @FocusState private var isTextEditorFocused: Bool

    private let maxCharLimit = 1000
    private let recipientEmail = "cskhgopyalignai@gmail.com"

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "133"
        return "\(short) (build \(build))"
    }

    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: Date())
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - 1. Category Selector Chips
                categorySelectorView

                // MARK: - 2. Content Card with Character Counter
                contentEditorCard

                // MARK: - 3. Photo Attachments Card (Max 3)
                photoAttachmentsCard

                // MARK: - 4. Submit Button
                submitButton

                // System Info Note
                systemNoteView
            }
            .padding(16)
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("Góp ý & Hỗ trợ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Xong") {
                    isTextEditorFocused = false
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.yellow)
            }
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposerView(
                recipient: recipientEmail,
                subject: "[\(selectedCategory.rawValue)] Góp ý AlignAI - \(timestampString) - v\(appVersionString)",
                body: buildEmailBody(),
                imagesData: selectedImagesData,
                logFileURL: CameraLogger.exportLogFileURL(),
                onFinish: { dismiss() }
            )
        }
        .alert("Chưa cấu hình app Mail", isPresented: $showNoMailAlert) {
            Button("Mở Mail mặc định (không kèm ảnh/log)") { openFallbackMailto() }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Máy chưa có tài khoản trong ứng dụng Mail của Apple nên không thể tự động đính kèm ảnh/nhật ký kỹ thuật. Bạn có thể mở ứng dụng gửi thư mặc định để gửi nhanh.")
        }
    }

    // MARK: - Category Selector
    private var categorySelectorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOẠI PHẢN HỒI")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.gray)

            HStack(spacing: 8) {
                ForEach(FeedbackCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedCategory = category
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: category.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(category.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.yellow : Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.yellow : Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .black : .white)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content Editor Card
    private var contentEditorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NỘI DUNG CHI TIẾT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)
                Spacer()
                Text("\(feedbackText.count)/\(maxCharLimit)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(feedbackText.count > maxCharLimit ? .red : .gray)
            }

            ZStack(alignment: .topLeading) {
                if feedbackText.isEmpty {
                    Text("Mô tả chi tiết lỗi gặp phải hoặc tính năng bạn muốn có trong AlignAI Camera...")
                        .font(.system(size: 14))
                        .foregroundColor(.gray.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }

                TextEditor(text: $feedbackText)
                    .focused($isTextEditorFocused)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(8)
                    .frame(minHeight: 140)
                    .onChange(of: feedbackText) { newValue in
                        if newValue.count > maxCharLimit {
                            feedbackText = String(newValue.prefix(maxCharLimit))
                        }
                    }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Photo Attachments Card
    private var photoAttachmentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ẢNH ĐÍNH KÈM (TỐI ĐA 3 ẢNH)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)
                Spacer()
                Text("\(selectedImagesData.count)/3")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
            }

            HStack(spacing: 10) {
                // Add Photos Button
                if selectedImagesData.count < 3 {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 3 - selectedImagesData.count,
                        matching: .images
                    ) {
                        VStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.yellow)
                            Text("Thêm ảnh")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .frame(width: 80, height: 80)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                )
                        )
                    }
                    .onChange(of: selectedPhotoItems) { newItems in
                        Task {
                            for item in newItems {
                                if let data = try? await item.loadTransferable(type: Data.self),
                                   selectedImagesData.count < 3 {
                                    selectedImagesData.append(data)
                                }
                            }
                            selectedPhotoItems = []
                        }
                    }
                }

                // Thumbnails
                ForEach(selectedImagesData.indices, id: \.self) { idx in
                    let data = selectedImagesData[idx]
                    if let uiImg = UIImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: uiImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )

                            Button(action: {
                                withAnimation {
                                    selectedImagesData.remove(at: idx)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.red)
                                    .background(Circle().fill(Color.black).padding(2))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Submit Button
    private var submitButton: some View {
        Button(action: {
            isTextEditorFocused = false
            if MFMailComposeViewController.canSendMail() {
                showMailComposer = true
            } else {
                showNoMailAlert = true
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("Gửi phản hồi")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSubmitDisabled ? Color.yellow.opacity(0.3) : Color.yellow)
            )
        }
        .disabled(isSubmitDisabled)
        .padding(.top, 6)
    }

    private var isSubmitDisabled: Bool {
        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - System Note
    private var systemNoteView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Text("Thư góp ý sẽ tự động đính kèm thông tin thiết bị (model máy, phiên bản iOS, phiên bản app \(appVersionString)) và trích xuất nhật ký lỗi kỹ thuật gần nhất để hỗ trợ gỡ lỗi nhanh hơn.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .lineSpacing(2)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers
    private func buildEmailBody() -> String {
        """
        --- GÓP Ý TỪ NGƯỜI DÙNG (\(selectedCategory.rawValue.uppercased())) ---
        \(feedbackText)

        --- THÔNG TIN THIẾT BỊ & HỆ THỐNG ---
        Thời gian: \(timestampString)
        Phiên bản app: \(appVersionString)
        Thiết bị: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
        Màn hình: \(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height)) @\(Int(UIScreen.main.scale))x
        Số ảnh đính kèm: \(selectedImagesData.count)

        --- TRÍCH XUẤT NHẬT KÝ KỸ THUẬT GẦN NHẤT ---
        \(CameraLogger.readRecentLogText())
        """
    }

    private func openFallbackMailto() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipientEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "[\(selectedCategory.rawValue)] Góp ý AlignAI - \(timestampString)"),
            URLQueryItem(name: "body", value: String(buildEmailBody().prefix(1800)))
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Multi-attachment MailComposerView
public struct MailComposerView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let imagesData: [Data]
    let logFileURL: URL?
    let onFinish: () -> Void

    public init(recipient: String, subject: String, body: String, imagesData: [Data], logFileURL: URL?, onFinish: @escaping () -> Void) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.imagesData = imagesData
        self.logFileURL = logFileURL
        self.onFinish = onFinish
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    public func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([recipient])
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)

        for (index, data) in imagesData.enumerated() {
            composer.addAttachmentData(data, mimeType: "image/jpeg", fileName: "gopy_anh_\(index + 1).jpg")
        }

        if let logURL = logFileURL, let logData = try? Data(contentsOf: logURL) {
            composer.addAttachmentData(logData, mimeType: "text/plain", fileName: "alignai_debug_log.txt")
        }
        return composer
    }

    public func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    public class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        public func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true) { self.onFinish() }
        }
    }
}
