import SwiftUI
import AVFoundation
import UIKit

// MARK: - PIP Container View (Direct Hardware Layer Hosting — Order-Safe Swap)
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
        if hostedLayer === layer, layer == nil || layer?.superlayer === self.layer {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Only detach old layer if it is still attached to THIS container (prevents ripping a swapped layer out of its new host!)
        if let old = hostedLayer, old !== layer, old.superlayer === self.layer {
            old.removeFromSuperlayer()
        }
        hostedLayer = layer
        if let layer {
            if layer.superlayer !== self.layer {
                layer.removeFromSuperlayer()
                self.layer.addSublayer(layer)
            }
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
        }
        CATransaction.commit()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Dual Camera PIP Preview View (UIViewRepresentable — Zero-Lag Swap Aware)
public struct DualCameraPIPPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> PIPContainerView {
        let view = PIPContainerView()
        let service = viewModel.cameraService
        let layer = viewModel.isDualCameraSwapped ? service.multiCamPrimaryPreviewLayer : service.secondaryPreviewLayer
        view.setPreviewLayer(service.isDualCameraActive ? layer : nil)
        return view
    }

    public func updateUIView(_ uiView: PIPContainerView, context: Context) {
        let service = viewModel.cameraService
        let layer = viewModel.isDualCameraSwapped ? service.multiCamPrimaryPreviewLayer : service.secondaryPreviewLayer
        uiView.setPreviewLayer(service.isDualCameraActive ? layer : nil)
    }

    public static func dismantleUIView(_ uiView: PIPContainerView, coordinator: ()) {
        uiView.setPreviewLayer(nil)
    }
}

// MARK: - Dual Camera PIP Draggable, Swappable & Scalable Studio Overlay
public struct DualCameraPIPOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize
    let topSafeInset: CGFloat
    let bottomSafeInset: CGFloat

    public typealias PIPCorner = DualCameraPIPCorner

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    @State private var isPinching: Bool = false
    @State private var lastPipScale: CGFloat = 1.0

    private let basePipWidth: CGFloat = 98
    private let basePipHeight: CGFloat = 131
    private let margin: CGFloat = 10

    public init(
        viewModel: CameraViewModel,
        containerSize: CGSize,
        topSafeInset: CGFloat = 44,
        bottomSafeInset: CGFloat = 56
    ) {
        self.viewModel = viewModel
        self.containerSize = containerSize
        self.topSafeInset = topSafeInset
        self.bottomSafeInset = bottomSafeInset
    }

    private var pipScale: CGFloat {
        max(0.75, min(1.75, viewModel.dualCameraPIPScale))
    }

    private var currentCorner: PIPCorner {
        viewModel.dualCameraPIPCorner
    }

    private var currentPipWidth: CGFloat {
        min(basePipWidth * pipScale, max(84, containerSize.width * 0.46))
    }

    private var currentPipHeight: CGFloat {
        currentPipWidth * (4.0 / 3.0)
    }

    private var minOriginX: CGFloat { margin }
    private var maxOriginX: CGFloat { max(margin, containerSize.width - margin - currentPipWidth) }
    private var minOriginY: CGFloat { max(margin, topSafeInset) }
    private var maxOriginY: CGFloat { max(minOriginY, containerSize.height - max(margin, bottomSafeInset) - currentPipHeight) }

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
        .onAppear {
            lastPipScale = pipScale
        }
    }

    @ViewBuilder
    private func pipCardView(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            DualCameraPIPPreviewView(viewModel: viewModel)
                .frame(width: width, height: height)
                .background(AlignTheme.studioCanvas)

            // Discreet Top Controls: Swap Front/Back (left) + Close DualCam (right)
            VStack {
                HStack(spacing: 4) {
                    Button(action: {
                        viewModel.swapDualCameraFeeds()
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Đổi vị trí camera trước và sau")

                    Spacer()

                    Button(action: {
                        viewModel.toggleDualCamera()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tắt Dual Cam")
                }
                .padding(6)
                Spacer()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.32), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.52), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isDragging)
        // Double-tap to cycle size cleanly: Compact -> Medium -> Large -> Compact
        .onTapGesture(count: 2) {
            let nextScale: CGFloat
            if pipScale < 1.12 {
                nextScale = 1.32
            } else if pipScale < 1.50 {
                nextScale = 1.62
            } else {
                nextScale = 1.0
            }
            viewModel.haptics.triggerSelectionChange()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.setDualCameraPIPScale(nextScale)
                lastPipScale = nextScale
            }
        }
        // Magnetic Corner Drag
        .gesture(
            DragGesture(minimumDistance: 6)
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
                    let projectedX = baseOrigin.x + value.predictedEndTranslation.width * 0.45 + value.translation.width * 0.55
                    let projectedY = baseOrigin.y + value.predictedEndTranslation.height * 0.45 + value.translation.height * 0.55

                    let isLeft = (projectedX + currentPipWidth * 0.5) < (containerSize.width * 0.5)
                    let isTop = (projectedY + currentPipHeight * 0.5) < (containerSize.height * 0.5)

                    let newCorner: PIPCorner
                    if isTop {
                        newCorner = isLeft ? .topLeading : .topTrailing
                    } else {
                        newCorner = isLeft ? .bottomLeading : .bottomTrailing
                    }

                    viewModel.haptics.triggerLight()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        viewModel.setDualCameraPIPCorner(newCorner)
                        self.dragOffset = .zero
                        self.isDragging = false
                    }
                }
        )
        // Smooth Pinch-to-Resize
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    isPinching = true
                    let targetScale = min(max(lastPipScale * value, 0.75), 1.75)
                    viewModel.setDualCameraPIPScale(targetScale)
                }
                .onEnded { _ in
                    lastPipScale = pipScale
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        isPinching = false
                    }
                }
        )
    }
}
