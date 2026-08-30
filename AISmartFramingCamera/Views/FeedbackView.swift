import SwiftUI
import MessageUI
import PhotosUI

public struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackText: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var showMailComposer = false
    @State private var showNoMailAlert = false
    
    private let recipientEmail = "cskhgopyalignai@gmail.com"
    
    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }
    
    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: Date())
    }
    
    public init() {}
    
    public var body: some View {
        Form {
            Section(header: Text("Nội dung góp ý")) {
                TextEditor(text: $feedbackText)
                    .frame(minHeight: 150)
            }
            
            Section(header: Text("Ảnh đính kèm (không bắt buộc)")) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    if let data = selectedImageData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                    } else {
                        Label("Chọn ảnh", systemImage: "photo.on.rectangle")
                    }
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self) {
                            selectedImageData = data
                        }
                    }
                }
            }
            
            Section {
                Button("Gửi góp ý") {
                    if MFMailComposeViewController.canSendMail() {
                        showMailComposer = true
                    } else {
                        showNoMailAlert = true
                    }
                }
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Góp ý & Hỗ trợ")
        .sheet(isPresented: $showMailComposer) {
            MailComposerView(
                recipient: recipientEmail,
                subject: "Góp ý AlignAI - \(timestampString) - v\(appVersionString)",
                body: buildEmailBody(),
                imageData: selectedImageData,
                logFileURL: CameraLogger.exportLogFileURL(),
                onFinish: { dismiss() }
            )
        }
        .alert("Chưa cấu hình app Mail", isPresented: $showNoMailAlert) {
            Button("Mở Mail mặc định (không kèm ảnh/log)") { openFallbackMailto() }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Máy chưa có tài khoản trong app Mail của Apple nên không tự đính kèm ảnh/log được. Có thể vào Cài đặt > Mail thêm tài khoản rồi thử lại, hoặc mở mail mặc định để gửi tay.")
        }
    }
    
    private func buildEmailBody() -> String {
        """
        --- GÓP Ý TỪ NGƯỜI DÙNG ---
        \(feedbackText)
        
        --- THÔNG TIN HỆ THỐNG ---
        Thời gian: \(timestampString)
        Phiên bản app: \(appVersionString)
        Thiết bị: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
        
        --- LOG GẦN NHẤT ---
        \(CameraLogger.readRecentLogText())
        """
    }
    
    private func openFallbackMailto() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipientEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Góp ý AlignAI - \(timestampString)"),
            URLQueryItem(name: "body", value: String(buildEmailBody().prefix(1800)))
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

public struct MailComposerView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let imageData: Data?
    let logFileURL: URL?
    let onFinish: () -> Void
    
    public init(recipient: String, subject: String, body: String, imageData: Data?, logFileURL: URL?, onFinish: @escaping () -> Void) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.imageData = imageData
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
        
        if let imageData = imageData {
            composer.addAttachmentData(imageData, mimeType: "image/jpeg", fileName: "gopy_anh.jpg")
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
