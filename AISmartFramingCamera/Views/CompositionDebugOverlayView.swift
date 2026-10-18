import SwiftUI

/// Overlay hien thi thong so chan doan va thuc nghiem bo cuc theo thoi gian thuc tren Viewfinder.
/// Kich hoat khi CompositionTuning.isDebugOverlayEnabled = true.
public struct CompositionDebugOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    private var qualityText: String {
        switch viewModel.trackingQuality {
        case .locked: return "locked"
        case .predicting: return "predicting"
        case .reacquiring: return "reacquiring"
        case .lost: return "lost"
        }
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Ve cac bounding box chan doan (Face / Hero / Objects)
            ForEach(0..<viewModel.detectedFaceRects.count, id: \.self) { idx in
                let r = viewModel.detectedFaceRects[idx]
                let lr = viewModel.convertMetadataRectToLayerRect(r, in: containerSize)
                Rectangle()
                    .stroke(Color.green.opacity(0.85), lineWidth: 1.5)
                    .frame(width: lr.width, height: lr.height)
                    .position(x: lr.midX, y: lr.midY)
                    .overlay(
                        Text("Face #\(idx + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.green)
                            .position(x: lr.minX + 24, y: max(10, lr.minY - 8))
                    )
            }

            // 2. HUD Thong so thuc nghiem o goc tren
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("COMPOSITION DEBUG HUD")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.orange)
                }

                let zoomStr = String(format: "%.2fx", viewModel.currentZoom)
                let suggStr = viewModel.aiSuggestedZoom.map { String(format: "%.2fx", $0) } ?? "none"
                Text("Zoom: \(zoomStr) | Sugg: \(suggStr)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)

                let targetStr = viewModel.currentTargetPoint.map { String(format: "(%.3f, %.3f)", $0.x, $0.y) } ?? "nil"
                Text("Target: \(targetStr)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.yellow)

                Text("Entities: \(viewModel.liveDetectedEntities.count) | Faces: \(viewModel.detectedFaceRects.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))

                Text("Track Quality: \(qualityText)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.trackingQuality == .locked ? .green : .orange)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.65))
            )
            .padding(.top, 54)
            .padding(.leading, 12)
            .allowsHitTesting(false)
        }
    }
}
