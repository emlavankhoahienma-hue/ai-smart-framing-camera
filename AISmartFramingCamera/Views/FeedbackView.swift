import SwiftUI
import UIKit
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

// MARK: - Feedback View (Pro-Camera Luxury Edition)
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

    // Design System Constants
    private let canvasBackground = Color(red: 0.035, green: 0.035, blue: 0.045)
    private let cardBackground = Color(red: 0.075, green: 0.075, blue: 0.090)
    private let amberGold = Color(red: 1.0, green: 0.72, blue: 0.0)
    private let cardStroke = Color.white.opacity(0.08)

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "171"
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

                // MARK: - 5. System Info Note
                systemNoteView
            }
            .padding(16)
        }
        .background(canvasBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("Góp ý & Hỗ trợ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Xong") {
                    isTextEditorFocused = false
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(amberGold)
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

    // MARK: - Category Selector Chips
    private var categorySelectorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(amberGold.opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: "tag.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(amberGold)
                }

                Text("CHUYÊN MỤC GÓP Ý")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.50))
            }

            HStack(spacing: 8) {
                ForEach(FeedbackCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button(action: {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            selectedCategory = category
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(category.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .bold : .medium, design: .rounded))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(isSelected ? amberGold : Color(red: 0.08, green: 0.08, blue: 0.10))
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? amberGold : Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .black : Color.white.opacity(0.85))
                        .shadow(color: isSelected ? amberGold.opacity(0.3) : Color.clear, radius: 6)
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
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(amberGold.opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(amberGold)
                }

                Text("NỘI DUNG CHI TIẾT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.50))

                Spacer()

                Text("\(feedbackText.count)/\(maxCharLimit)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(feedbackText.count >= maxCharLimit ? .red : (feedbackText.count > 900 ? amberGold : Color.white.opacity(0.40)))
            }

            ZStack(alignment: .topLeading) {
                if feedbackText.isEmpty {
                    Text("Mô tả chi tiết lỗi bạn gặp phải hoặc đề xuất tính năng mới mà bạn muốn có trong AlignAI Camera...")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.35))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .lineSpacing(3)
                }

                TextEditor(text: $feedbackText)
                    .focused($isTextEditorFocused)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(10)
                    .frame(minHeight: 150)
                    .onChange(of: feedbackText) { newValue in
                        if newValue.count > maxCharLimit {
                            feedbackText = String(newValue.prefix(maxCharLimit))
                        }
                    }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(cardStroke, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Photo Attachments Card (Max 3)
    private var photoAttachmentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(amberGold.opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(amberGold)
                }

                Text("ẢNH MINH HỌA (TỐI ĐA 3 ẢNH)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.50))

                Spacer()

                Text("\(selectedImagesData.count)/3")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(amberGold)
            }

            HStack(spacing: 12) {
                if selectedImagesData.count < 3 {
                    addPhotoPickerButton
                }

                ForEach(0..<selectedImagesData.count, id: \.self) { idx in
                    thumbnailPreview(index: idx)
                }

                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private var addPhotoPickerButton: some View {
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, 3 - selectedImagesData.count),
            matching: .images
        ) {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(amberGold)
                Text("Thêm ảnh")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.85))
            }
            .frame(width: 84, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(amberGold.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    )
            )
        }
        .onChange(of: selectedPhotoItems) { newItems in
            handlePickedPhotos(newItems)
        }
    }

    @ViewBuilder
    private func thumbnailPreview(index: Int) -> some View {
        if index < selectedImagesData.count, let uiImg = UIImage(data: selectedImagesData[index]) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )

                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        if index < selectedImagesData.count {
                            selectedImagesData.remove(at: index)
                        }
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red)
                        .background(Circle().fill(Color.black).padding(2))
                }
                .offset(x: 6, y: -6)
            }
        }
    }

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        if selectedImagesData.count < 3 {
                            selectedImagesData.append(data)
                        }
                    }
                }
            }
            await MainActor.run {
                selectedPhotoItems = []
            }
        }
    }

    // MARK: - Submit Button
    private var submitButton: some View {
        Button(action: {
            isTextEditorFocused = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSubmitDisabled ? amberGold.opacity(0.35) : amberGold)
            )
            .shadow(color: isSubmitDisabled ? Color.clear : amberGold.opacity(0.35), radius: 10, x: 0, y: 3)
        }
        .disabled(isSubmitDisabled)
        .padding(.top, 4)
    }

    private var isSubmitDisabled: Bool {
        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - System Note
    private var systemNoteView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(amberGold)
                .padding(.top, 1)

            Text("Thư góp ý sẽ tự động đính kèm thông tin thiết bị (model máy, phiên bản iOS, phiên bản app \(appVersionString)) và trích xuất nhật ký lỗi kỹ thuật gần nhất từ CameraLogger để hỗ trợ xử lý nhanh nhất.")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.50))
                .lineSpacing(2.5)
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
