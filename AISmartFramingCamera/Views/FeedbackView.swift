import SwiftUI
import UIKit
import MessageUI
import PhotosUI

public enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug = "Báo lỗi"
    case feature = "Đề xuất tính năng"
    case other = "Góp ý khác"
    public var id: String { rawValue }
}

public struct FeedbackView: View {
    @State private var category = FeedbackCategory.bug
    @State private var message = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachments: [Data] = []
    @State private var showComposer = false
    @State private var noMail = false
    @State private var includeLogs = true
    @FocusState private var editing: Bool
    public init() {}
    public var body: some View {
        Form {
            Section("Bạn muốn chia sẻ điều gì?") {
                Picker("Chủ đề", selection: $category) {
                    ForEach(FeedbackCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                TextEditor(text: $message).frame(minHeight: 160).focused($editing)
                    .accessibilityLabel("Nội dung góp ý")
                    .onChange(of: message) { if $0.count > 1000 { message = String($0.prefix(1000)) } }
                Text("\(message.count)/1000 ký tự").font(.caption).foregroundColor(.secondary)
            }
            Section("Ảnh đính kèm") {
                PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, 3 - attachments.count), matching: .images) {
                    Label("Thêm ảnh (tối đa 3)", systemImage: "photo.badge.plus")
                }.disabled(attachments.count >= 3)
                ForEach(attachments.indices, id: \.self) { index in
                    HStack {
                        if let image = UIImage(data: attachments[index]) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 60, height: 60).clipped().cornerRadius(8)
                        }
                        Text("Ảnh \(index + 1)")
                        Spacer()
                        Button(role: .destructive) { attachments.remove(at: index) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("Xóa ảnh \(index + 1)")
                    }
                }
            }
            Section {
                Toggle("Đính kèm nhật ký chẩn đoán", isOn: $includeLogs)
                Button {
                    editing = false
                    if MFMailComposeViewController.canSendMail() { showComposer = true } else { noMail = true }
                } label: { Label("Soạn thư góp ý", systemImage: "envelope").frame(minHeight: 44) }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Bạn sẽ xem lại nội dung trong ứng dụng Mail trước khi gửi. Thư bao gồm phiên bản ứng dụng và thiết bị.")
            }
        }
        .navigationTitle("Góp ý & Hỗ trợ").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Xong") { editing = false } } }
        .task(id: photoItems) {
            guard !photoItems.isEmpty else { return }
            let selected = photoItems
            for item in selected {
                guard !Task.isCancelled else { return }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85), attachments.count < 3 {
                    attachments.append(jpeg)
                }
            }
            photoItems = []
        }
        .sheet(isPresented: $showComposer) {
            MailComposerView(recipient: "cskhgopyalignai@gmail.com", subject: "[\(category.rawValue)] AlignAI", body: emailBody,
                             imagesData: attachments, logFileURL: includeLogs ? CameraLogger.exportLogFileURL() : nil) {
                showComposer = false
            }
        }
        .alert("Chưa có tài khoản Mail", isPresented: $noMail) {
            Button("Mở ứng dụng thư") { openMail() }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Thư mở bằng liên kết sẽ không kèm ảnh và tệp nhật ký.") }
    }
    private var emailBody: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "\(message)\n\nAlignAI \(version) · \(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
    }
    private func openMail() {
        var url = URLComponents()
        url.scheme = "mailto"; url.path = "cskhgopyalignai@gmail.com"
        url.queryItems = [URLQueryItem(name: "subject", value: "[\(category.rawValue)] AlignAI"), URLQueryItem(name: "body", value: emailBody)]
        if let address = url.url { UIApplication.shared.open(address) }
    }
}
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
