import SwiftUI
import AVFoundation
import UIKit

// MARK: - PIP Container View (Direct Hardware Layer Hosting)
@MainActor
public class PIPContainerView: UIView {
    private var hostedLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    public func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        guard hostedLayer !== layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = layer
        if let layer {
            layer.removeFromSuperlayer()
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
        }
        CATransaction.commit()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        hostedLayer?.frame = bounds
    }
}

// MARK: - Dual Camera PIP Preview View (UIViewRepresentable)
public struct DualCameraPIPPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> PIPContainerView {
        let view = PIPContainerView()
        view.setPreviewLayer(viewModel.cameraService.secondaryPreviewLayer)
        return view
    }

    public func updateUIView(_ uiView: PIPContainerView, context: Context) {
        let service = viewModel.cameraService
        uiView.setPreviewLayer(service.isDualCameraActive ? service.secondaryPreviewLayer : nil)
    }

    public static func dismantleUIView(_ uiView: PIPContainerView, coordinator: ()) {
        uiView.setPreviewLayer(nil)
    }
}

// MARK: - Dual Camera PIP Draggable & Scalable Overlay View
public struct DualCameraPIPOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    public typealias PIPCorner = DualCameraPIPCorner

    @State private var currentCorner: PIPCorner = .topTrailing
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    // Tỉ lệ kích thước khung camera trước (0.75x đến 1.8x)
    @State private var pipScale: CGFloat = 1.0
    @State private var lastPipScale: CGFloat = 1.0

    private let basePipWidth: CGFloat = 96
    private let basePipHeight: CGFloat = 128
    private let margin: CGFloat = 10

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    private var currentPipWidth: CGFloat {
        basePipWidth * pipScale
    }

    private var currentPipHeight: CGFloat {
        basePipHeight * pipScale
    }

    private var basePosition: CGPoint {
        let halfW = currentPipWidth / 2
        let halfH = currentPipHeight / 2
        let minX = margin + halfW
        let maxX = max(minX, containerSize.width - margin - halfW)
        let minY = margin + 34 + halfH // Bên dưới audio VU meter
        let maxY = max(minY, containerSize.height - margin - 46 - halfH) // Bên trên thanh zoom pill

        switch currentCorner {
        case .topLeading:
            return CGPoint(x: minX, y: minY)
        case .topTrailing:
            return CGPoint(x: maxX, y: minY)
        case .bottomLeading:
            return CGPoint(x: minX, y: maxY)
        case .bottomTrailing:
            return CGPoint(x: maxX, y: maxY)
        }
    }

    private var clampedPosition: CGPoint {
        let rawX = basePosition.x + dragOffset.width
        let rawY = basePosition.y + dragOffset.height
        let halfW = currentPipWidth / 2
        let halfH = currentPipHeight / 2
        let minX = margin + halfW
        let maxX = max(minX, containerSize.width - margin - halfW)
        let minY = margin + 34 + halfH
        let maxY = max(minY, containerSize.height - margin - 46 - halfH)
        return CGPoint(
            x: max(minX, min(maxX, rawX)),
            y: max(minY, min(maxY, rawY))
        )
    }

    public var body: some View {
        let currentW = currentPipWidth
        let currentH = currentPipHeight

        ZStack {
            DualCameraPIPPreviewView(viewModel: viewModel)
                .frame(width: currentW, height: currentH)
                .background(Color.black)

            // Header: Nút đóng góc phải trên gọn gàng (đã bỏ chữ PIP và chấm tròn)
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        viewModel.toggleDualCamera()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(6)
                Spacer()
            }
        }
        .frame(width: currentW, height: currentH)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            // Viền màu trắng đơn giản, tinh tế
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.65), radius: 8, y: 3)
        .scaleEffect(isDragging ? 1.04 : 1.0)
        .position(clampedPosition)
        // Chạm đúp 2 lần để đổi nhanh kích thước: Nhỏ -> Vừa -> Lớn -> Nhỏ
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                if pipScale < 1.15 {
                    pipScale = 1.35
                } else if pipScale < 1.55 {
                    pipScale = 1.70
                } else {
                    pipScale = 1.0
                }
                lastPipScale = pipScale
            }
            viewModel.setDualCameraPIPScale(pipScale)
        }
        // Kéo di chuyển vị trí khung camera
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let finalX = basePosition.x + value.translation.width
                    let finalY = basePosition.y + value.translation.height

                    let isLeft = finalX < (containerSize.width / 2)
                    let isTop = finalY < (containerSize.height / 2)

                    let newCorner: PIPCorner
                    if isTop {
                        newCorner = isLeft ? .topLeading : .topTrailing
                    } else {
                        newCorner = isLeft ? .bottomLeading : .bottomTrailing
                    }

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        self.currentCorner = newCorner
                        self.dragOffset = .zero
                        self.isDragging = false
                    }
                    viewModel.setDualCameraPIPCorner(newCorner)
                }
        )
        // Chụm 2 ngón tay để phóng to/thu nhỏ khung hình mượt mà
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let targetScale = min(max(lastPipScale * value, 0.75), 1.8)
                    pipScale = targetScale
                }
                .onEnded { _ in
                    lastPipScale = pipScale
                    viewModel.setDualCameraPIPScale(pipScale)
                }
        )
    }
}
