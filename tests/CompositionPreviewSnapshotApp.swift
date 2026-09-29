// Used only by the simulator snapshot workflow; never included in the production target.
import SwiftUI
import UIKit

@main
struct CompositionPreviewSnapshotApp: App {
    var body: some Scene {
        WindowGroup { SnapshotHost().preferredColorScheme(.dark) }
    }
}

private struct SnapshotHost: View {
    @State private var showing = true
    private let choices = Self.makeChoices()

    var body: some View {
        Color.black
            .sheet(isPresented: $showing) {
                CompositionPreviewSheet(choices: choices,
                    onSelect: { _ in showing = false }, onCancel: { showing = false })
            }
    }

    private static func makeChoices() -> [LocalCompositionChoice] {
        let variants: [(LocalCompositionIntent, CGFloat, CGFloat, String)] = [
            (.environmentalPortrait, 1, 0.36, "Giữ người cùng bối cảnh để ảnh có câu chuyện. Mép khung ít chi tiết gây phân tán."),
            (.portrait, 1.65, 0.5, "Ưu tiên người và khoảng đầu. Chừa khoảng trống theo hướng quay đầu."),
            (.landscape, 1, 0.68, "Giữ các vùng nổi bật và không gian của cảnh.")
        ]
        return variants.compactMap { intent, zoom, x, explanation -> LocalCompositionChoice? in
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 216, height: 288))
            let image = renderer.image { canvas in
                let context = canvas.cgContext
                UIColor(red: 0.53, green: 0.72, blue: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 216, height: 288))
                UIColor(red: 0.25, green: 0.46, blue: 0.41, alpha: 1).setFill()
                context.move(to: CGPoint(x: 0, y: 165))
                context.addLine(to: CGPoint(x: 85, y: 90))
                context.addLine(to: CGPoint(x: 165, y: 160))
                context.addLine(to: CGPoint(x: 216, y: 116))
                context.addLine(to: CGPoint(x: 216, y: 288))
                context.addLine(to: CGPoint(x: 0, y: 288))
                context.closePath()
                context.fillPath()
                UIColor(red: 0.67, green: 0.67, blue: 0.40, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 224, width: 216, height: 64))
                let personX = x * 216
                let height = 100 * zoom
                UIColor(red: 0.91, green: 0.77, blue: 0.60, alpha: 1).setFill()
                context.fillEllipse(in: CGRect(x: personX - 12 * zoom, y: 263 - height,
                                               width: 24 * zoom, height: 26 * zoom))
                UIColor(red: 0.80, green: 0.33, blue: 0.20, alpha: 1).setFill()
                context.fill(CGRect(x: personX - 18 * zoom, y: 283 - height,
                                    width: 36 * zoom, height: height - 20))
            }
            guard let preview = image.cgImage else { return nil }
            let rect = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.5)
            let point = CGPoint(x: 0.4, y: 0.4)
            let candidate = NeuralSubjectCandidate(boundingBox: rect, category: .human,
                confidence: 0.9, label: intent.title, prominenceScore: 1)
            let plan = LocalFramingPlan(subjectPoint: point, subjectRect: rect,
                aimPointInSource: point, aimWorldRay: SIMD3(0, 0, -1), zoom: zoom,
                confidence: 0.9, minimumAutoselectConfidence: 0.72, intent: intent,
                score: 0.8, explanation: explanation, usesCenter: x == 0.5,
                preferenceKey: intent.rawValue)
            return LocalCompositionChoice(candidate: candidate, plan: plan, preview: preview)
        }
    }
}
