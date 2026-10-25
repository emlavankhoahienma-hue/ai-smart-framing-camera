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
    @State private var isPinching: Bool = false

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

    private var minOriginX: CGFloat { margin }
    private var maxOriginX: CGFloat { max(margin, containerSize.width - margin - currentPipWidth) }
    private var minOriginY: CGFloat { margin + 34 } // Bên dưới audio VU meter
    private var maxOriginY: CGFloat { max(minOriginY, containerSize.height - margin - 46 - currentPipHeight) } // Bên trên thanh zoom pill

    private var baseOrigin: CGPoint {
        switch currentCorner {
        case .topLeading:
            return CGPoint(x: minOriginX, y: minOriginY)
        case .topTrailing:
            return CGPoint(x: maxOriginX, y: minOriginY)
        case .bottomLeading:
            return CGPoint(x: minOriginX, y: maxOriginY)
        case .bottomTrailing:
            return CGPoint(x: maxOriginX, y: maxOriginY)
        }
    }

    private var clampedOrigin: CGPoint {
        let rawX = baseOrigin.x + dragOffset.width
        let rawY = baseOrigin.y + dragOffset.height
        return CGPoint(
            x: max(minOriginX, min(maxOriginX, rawX)),
            y: max(minOriginY, min(maxOriginY, rawY))
        )
    }

    public var body: some View {
        let currentW = currentPipWidth
        let currentH = currentPipHeight
        let origin = clampedOrigin

        ZStack(alignment: .topLeading) {
            pipCardView(width: currentW, height: currentH)
                .offset(x: origin.x, y: origin.y)
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func pipCardView(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            DualCameraPIPPreviewView(viewModel: viewModel)
                .frame(width: width, height: height)
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
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.black.opacity(0.60)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(6)
                Spacer()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            // Viền màu trắng đơn giản, tinh tế
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.65), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isDragging ? 1.04 : 1.0)
        // Chạm đúp 2 lần để đổi nhanh kích thước: Nhỏ -> Vừa -> Lớn -> Nhỏ
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
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
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard !isPinching else { return }
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    guard !isPinching else {
                        isDragging = false
                        dragOffset = .zero
                        return
                    }
                    let finalX = baseOrigin.x + value.translation.width
                    let finalY = baseOrigin.y + value.translation.height

                    let isLeft = (finalX + currentPipWidth / 2) < (containerSize.width / 2)
                    let isTop = (finalY + currentPipHeight / 2) < (containerSize.height / 2)

                    let newCorner: PIPCorner
                    if isTop {
                        newCorner = isLeft ? .topLeading : .topTrailing
                    } else {
                        newCorner = isLeft ? .bottomLeading : .bottomTrailing
                    }

                    withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
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
                    isPinching = true
                    let targetScale = min(max(lastPipScale * value, 0.75), 1.8)
                    pipScale = targetScale
                }
                .onEnded { _ in
                    lastPipScale = pipScale
                    viewModel.setDualCameraPIPScale(pipScale)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isPinching = false
                    }
                }
        )
    }
}
