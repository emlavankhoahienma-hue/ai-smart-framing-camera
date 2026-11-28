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

    public var shortTitle: String {
        switch self {
        case .bug: return "Báo lỗi"
        case .feature: return "Tính năng"
        case .other: return "Góp ý khác"
        }
    }

    public var icon: String {
        switch self {
        case .bug: return "exclamationmark.triangle"
        case .feature: return "sparkles"
        case .other: return "bubble.left.and.text.bubble.right"
        }
    }

    public var placeholderText: String {
        switch self {
        case .bug:
            return "Mô tả lỗi bạn gặp phải, các bước thực hiện và thời điểm xảy ra để đội ngũ tái hiện và xử lý nhanh nhất..."
        case .feature:
            return "Chia sẻ tính năng mới hoặc điểm bạn muốn cải thiện trên Align Studio Camera..."
        case .other:
            return "Góp ý của bạn về giao diện, chất lượng ảnh/video hoặc trải nghiệm sử dụng hàng ngày..."
        }
    }
}

// MARK: - Feedback View (Unified Align Studio Monochrome + Warm Titanium Form)
public struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: FeedbackCategory = .bug
    @State private var feedbackText: String = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedImagesData: [Data] = []
    @State private var showMailComposer = false
    @State private var showNoMailAlert = false
    @State private var toastMessage: String? = nil
    @FocusState private var isTextEditorFocused: Bool

    private let maxCharLimit = 1000
    private let recipientEmail = "cskhgopyalignai@gmail.com"

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: Date())
    }

    public init() {}

    public var body: some View {
        ZStack {
            AlignTheme.studioCanvas
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    studioIntroHeader
                    categorySelectorSection
                    contentEditorSection
                    photoAttachmentsSection
                    diagnosticSummaryCard
                    submitActionSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)

            if let msg = toastMessage {
                VStack {
                    Spacer()
                    ToastBanner(message: msg)
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Góp ý & Hỗ trợ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Xong") {
                    isTextEditorFocused = false
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AlignTheme.studioAccent)
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
        .alert("Chưa cấu hình ứng dụng Mail", isPresented: $showNoMailAlert) {
            Button("Mở ứng dụng thư mặc định") { openFallbackMailto() }
            Button("Sao chép email hỗ trợ") { copySupportEmail() }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Thiết bị chưa đăng nhập tài khoản trong ứng dụng Apple Mail nên không thể tự động đính kèm ảnh và tệp log. Bạn có thể mở ứng dụng thư mặc định hoặc sao chép địa chỉ email để gửi thủ công.")
        }
    }

    // MARK: - 1. Calm Studio Intro Header
    private var studioIntroHeader: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(AlignTheme.studioElevated)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle().stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                    )
                Image(systemName: "envelope.open")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(AlignTheme.studioAccent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Gửi phản hồi tới Align Studio")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkPrimary)

                Text("Mọi góp ý được đọc trực tiếp. Nhật ký kỹ thuật sẽ được đính kèm an toàn để xử lý lỗi nhanh hơn.")
                    .font(.system(size: 12))
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AlignTheme.studioSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
                )
        )
    }

    // MARK: - 2. Equal 3-Column Category Cards (Zero Clipping / Zero Wrapping)
    private var categorySelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHUYÊN MỤC")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(AlignTheme.studioInkSecondary)
                .padding(.horizontal, 2)

            HStack(spacing: 8) {
                ForEach(FeedbackCategory.allCases) { category in
                    let isSelected = (selectedCategory == category)
                    Button(action: {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            selectedCategory = category
                        }
                    }) {
                        VStack(spacing: 7) {
                            Image(systemName: category.icon)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)

                            Text(category.shortTitle)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                                .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 0.9 : 0.65)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 3. Refined Multi-line Content Editor
    private var contentEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NỘI DUNG CHI TIẾT")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(AlignTheme.studioInkSecondary)

                Spacer()

                Text("\(feedbackText.count)/\(maxCharLimit)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(
                        feedbackText.count >= maxCharLimit
                            ? AlignTheme.studioRecordRed
                            : (feedbackText.count > 850 ? AlignTheme.studioAccent : AlignTheme.studioInkTertiary)
                    )
            }
            .padding(.horizontal, 2)

            ZStack(alignment: .topLeading) {
                if feedbackText.isEmpty {
                    Text(selectedCategory.placeholderText)
                        .font(.system(size: 14))
                        .foregroundColor(AlignTheme.studioInkTertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .lineSpacing(3)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $feedbackText)
                    .focused($isTextEditorFocused)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 148)
                    .onChangeCompatible(of: feedbackText) { newValue in
                        if newValue.count > maxCharLimit {
                            feedbackText = String(newValue.prefix(maxCharLimit))
                        }
                    }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AlignTheme.studioSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isTextEditorFocused ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle,
                                lineWidth: isTextEditorFocused ? 0.9 : 0.7
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.16), value: isTextEditorFocused)
        }
    }

    // MARK: - 4. Uniform 3-Slot Photo Attachment Tray
    private var photoAttachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ẢNH MINH HỌA")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(AlignTheme.studioInkSecondary)

                Spacer()

                Text("\(selectedImagesData.count)/3")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(selectedImagesData.isEmpty ? AlignTheme.studioInkTertiary : AlignTheme.studioAccent)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 10) {
                ForEach(0..<selectedImagesData.count, id: \.self) { idx in
                    attachmentThumbnailSlot(index: idx)
                }

                if selectedImagesData.count < 3 {
                    addPhotoSlotButton
                }

                if selectedImagesData.count < 2 {
                    ForEach(0..<(2 - selectedImagesData.count), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AlignTheme.studioSurface.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .frame(height: 88)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AlignTheme.studioHairlineSubtle.opacity(0.6), lineWidth: 0.6)
                            )
                    }
                }
            }
        }
    }

    private var addPhotoSlotButton: some View {
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, 3 - selectedImagesData.count),
            matching: .images
        ) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(AlignTheme.studioAccent)
                Text("Thêm ảnh")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AlignTheme.studioSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AlignTheme.studioHairline, style: StrokeStyle(lineWidth: 0.9, dash: [4, 4]))
                    )
            )
        }
        .buttonStyle(.plain)
        .onChangeCompatible(of: selectedPhotoItems) { newItems in
            handlePickedPhotos(newItems)
        }
    }

    @ViewBuilder
    private func attachmentThumbnailSlot(index: Int) -> some View {
        if index < selectedImagesData.count, let uiImg = UIImage(data: selectedImagesData[index]) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                    )

                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        if index < selectedImagesData.count {
                            selectedImagesData.remove(at: index)
                        }
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("Xóa ảnh đính kèm")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
        }
    }

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
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

    // MARK: - 5. Diagnostic & Support Channel Summary Card
    private var diagnosticSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THÔNG TIN ĐÍNH KÈM")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(AlignTheme.studioInkSecondary)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                summaryRow(label: "Phiên bản ứng dụng", value: "v\(appVersionString)")
                Divider().background(AlignTheme.studioHairlineSubtle)
                summaryRow(label: "Hệ thống", value: "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)")
                Divider().background(AlignTheme.studioHairlineSubtle)

                HStack {
                    Text("Nhật ký CameraLogger")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(AlignTheme.studioPositive)
                            .frame(width: 6, height: 6)
                        Text("Tự động đính kèm")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                    }
                }
                .padding(.vertical, 10)

                Divider().background(AlignTheme.studioHairlineSubtle)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Email hỗ trợ")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioInkSecondary)
                        Text(recipientEmail)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { copySupportEmail() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Sao chép")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(AlignTheme.studioInkPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(AlignTheme.studioElevated)
                                .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AlignTheme.studioSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
                    )
            )
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(AlignTheme.studioInkSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkPrimary)
        }
        .padding(.vertical, 10)
    }

    // MARK: - 6. High-Contrast Studio Primary CTA Pill
    private var submitActionSection: some View {
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
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Gửi phản hồi")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isSubmitDisabled ? AlignTheme.studioInkTertiary : .black)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                Capsule()
                    .fill(isSubmitDisabled ? AlignTheme.studioElevated : AlignTheme.studioInkPrimary)
                    .overlay(
                        Capsule()
                            .stroke(isSubmitDisabled ? AlignTheme.studioHairlineSubtle : Color.clear, lineWidth: 0.7)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitDisabled)
        .padding(.top, 2)
    }

    private var isSubmitDisabled: Bool {
        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Helpers
    private func copySupportEmail() {
        UIPasteboard.general.string = recipientEmail
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast("Đã sao chép email: \(recipientEmail)")
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            toastMessage = msg
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.22)) {
                if toastMessage == msg {
                    toastMessage = nil
                }
            }
        }
    }

    private func buildEmailBody() -> String {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
        let bounds = screen?.bounds ?? .zero
        let scale = screen?.scale ?? 1
        return """
        --- GÓP Ý TỪ NGƯỜI DÙNG (\(selectedCategory.rawValue.uppercased())) ---
        \(feedbackText)

        --- THÔNG TIN THIẾT BỊ & HỆ THỐNG ---
        Thời gian: \(timestampString)
        Phiên bản app: \(appVersionString)
        Thiết bị: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
        Màn hình: \(Int(bounds.width))x\(Int(bounds.height)) @\(Int(scale))x
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
