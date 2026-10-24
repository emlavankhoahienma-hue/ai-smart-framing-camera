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

// MARK: - Dual Camera PIP Draggable Overlay View
public struct DualCameraPIPOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    public typealias PIPCorner = DualCameraPIPCorner

    @State private var currentCorner: PIPCorner = .topTrailing
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    private let pipWidth: CGFloat = 96
    private let pipHeight: CGFloat = 128
    private let margin: CGFloat = 10

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    private var basePosition: CGPoint {
        let minX = margin + pipWidth / 2
        let maxX = max(minX, containerSize.width - margin - pipWidth / 2)
        let minY = margin + 34 + pipHeight / 2 // Bên dưới audio VU meter
        let maxY = max(minY, containerSize.height - margin - 46 - pipHeight / 2) // Bên trên thanh zoom pill

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

    public var body: some View {
        let currentPos = basePosition
        ZStack {
            DualCameraPIPPreviewView(viewModel: viewModel)
                .frame(width: pipWidth, height: pipHeight)
                .background(Color.black)

            // Header Badge (Live Indicator + Close)
            VStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(AlignTheme.electricCyan)
                        .frame(width: 5, height: 5)
                        .shadow(color: AlignTheme.electricCyan, radius: 3)
                    Text("PIP")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                    Spacer()
                    Button(action: {
                        viewModel.toggleDualCamera()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                Spacer()
            }
        }
        .frame(width: pipWidth, height: pipHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AlignTheme.rimGradient, lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.65), radius: 8, y: 3)
        .scaleEffect(isDragging ? 1.04 : 1.0)
        .position(x: currentPos.x + dragOffset.width, y: currentPos.y + dragOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let finalX = currentPos.x + value.translation.width
                    let finalY = currentPos.y + value.translation.height

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
    }
}
