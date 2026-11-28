import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    public var body: some View {
        // Chỉ hiện thanh trạng thái duy nhất khi phiên căn bố cục đang hoạt động hoặc vừa chụp xong
        if viewModel.aiSessionState != .idle {
            HStack(spacing: 7) {
                Image(systemName: statusIconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusAccentColor)

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .lineLimit(1)

                if viewModel.aiSessionState.isTargetPlacedOrAligned && viewModel.pendingSuggestedZoom > 1.05 {
                    Text(String(format: "%.1fx", viewModel.pendingSuggestedZoom))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(AlignTheme.studioAccentSoft)
                        )
                }

                if viewModel.activeAIIndicatorType == .cloud {
                    Text("CLOUD")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Capsule().stroke(AlignTheme.studioAccentBorder, lineWidth: 0.5))
                        )
                } else if viewModel.activeAIIndicatorType == .local {
                    Text("LOCAL")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkPrimary.opacity(0.82))
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(StudioGlassCapsule(tintOpacity: 0.52, borderOpacity: 0.14))
            .shadow(color: Color.black.opacity(0.30), radius: 8, x: 0, y: 2)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.easeInOut(duration: 0.22), value: viewModel.aiSessionState)
        }
    }

    private var statusIconName: String {
        switch viewModel.aiSessionState {
        case .idle:
            return "viewfinder"
        case .analyzing:
            return "viewfinder"
        case .targetPlaced:
            if viewModel.trackingQuality == .reacquiring || viewModel.trackingQuality == .lost {
                return "arrow.triangle.2.circlepath"
            }
            return "scope"
        case .alignmentPerfect:
            return "checkmark.circle.fill"
        case .capturing:
            return "camera.fill"
        case .done:
            return "checkmark"
        }
    }

    private var statusAccentColor: Color {
        switch viewModel.aiSessionState {
        case .idle: return AlignTheme.studioInkPrimary.opacity(0.80)
        case .analyzing: return AlignTheme.studioAccent
        case .targetPlaced:
            if viewModel.trackingQuality == .reacquiring || viewModel.trackingQuality == .lost {
                return AlignTheme.studioInkSecondary
            }
            return AlignTheme.studioAccent
        case .alignmentPerfect: return AlignTheme.studioPositive
        case .capturing: return AlignTheme.studioInkPrimary
        case .done: return AlignTheme.studioPositive
        }
    }

    private var statusText: String {
        switch viewModel.aiSessionState {
        case .idle:
            return "Bố cục thông minh"
        case .analyzing:
            return "Đang phân tích bố cục…"
        case .targetPlaced:
            return "Lia máy vào khung"
        case .alignmentPerfect:
            return "Khóa nét & Bố cục hoàn hảo"
        case .capturing:
            return "Đang chụp…"
        case .done:
            return "Đã chụp ảnh"
        }
    }
}

/// Optional on-device Zoom Debug Overlay (default OFF, toggled in Settings -> Bố cục).
/// Renders hero box, detected distractor ("rác") boxes, predicted post-zoom viewport frame,
/// and live decision telemetry (role, fill ratio, clutter score, zoom state & reasonCode).
public struct ZoomDebugOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .topLeading) {
                if let snap = viewModel.zoomDebugSnapshot {
                    // 1. Predicted post-zoom crop frame (cyan/amber dashed)
                    if snap.predictedPostZoomFrame.width < 0.985 || snap.predictedPostZoomFrame.height < 0.985 {
                        let pf = snap.predictedPostZoomFrame
                        Rectangle()
                            .stroke(
                                Color.cyan.opacity(0.92),
                                style: StrokeStyle(lineWidth: 1.8, dash: [6, 4])
                            )
                            .frame(width: max(4, pf.width * w), height: max(4, pf.height * h))
                            .position(x: pf.midX * w, y: pf.midY * h)
                    }

                    // 2. Detected clutter / distractor boxes (magenta dashed)
                    ForEach(Array(snap.distractorBoxes.prefix(12).enumerated()), id: \.offset) { _, dBox in
                        Rectangle()
                            .stroke(
                                Color(red: 1.0, green: 0.25, blue: 0.65).opacity(0.88),
                                style: StrokeStyle(lineWidth: 1.4, dash: [4, 3])
                            )
                            .frame(width: max(4, dBox.width * w), height: max(4, dBox.height * h))
                            .position(x: dBox.midX * w, y: dBox.midY * h)
                    }

                    // 3. Primary hero bounding box (emerald green)
                    let hb = snap.heroBounds
                    Rectangle()
                        .stroke(Color.green.opacity(0.95), lineWidth: 2.0)
                        .frame(width: max(6, hb.width * w), height: max(6, hb.height * h))
                        .position(x: hb.midX * w, y: hb.midY * h)

                    // 4. Compact telemetry card (top-left)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(stateBadgeColor(snap.zoomState))
                                .frame(width: 7, height: 7)
                            Text("ZOOM DEBUG · \(snap.zoomState)")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Text("Hero: \(snap.heroLabel) [\(snap.role)]")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                        Text(String(
                            format: "Fill: %.0f%%→%.0f%% (ideal %.0f%%) · Gain %+.2f",
                            snap.subjectFill * 100, snap.projectedFill * 100, snap.idealFill * 100, snap.scoreGain
                        ))
                            .font(.system(size: 9.0, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.92))
                        Text(String(
                            format: "Clutter: %.0f%%→%.0f%% · Rác: %d · Cuts: %d→%d",
                            snap.clutterBefore * 100, snap.clutterAfter * 100,
                            snap.distractorBoxes.count, snap.partialEdgeCutsBefore, snap.partialEdgeCutsAfter
                        ))
                            .font(.system(size: 9.0, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.85))
                        Text(String(
                            format: "Zoom: %.1fx → imm %.1fx / pan %.1fx",
                            Double(snap.currentZoom), Double(snap.immediateZoom), Double(snap.postPanZoom)
                        ))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan)
                        Text("Reason: \(snap.reasonCode)")
                            .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                            )
                    )
                    .padding(.top, 52)
                    .padding(.leading, 8)
                } else {
                    Text("ZOOM DEBUG ON · Bấm AI để phân tích")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.68)))
                        .padding(.top, 52)
                        .padding(.leading, 8)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func stateBadgeColor(_ state: String) -> Color {
        switch state {
        case "ZOOM_IN", "GROUP_ZOOM": return .cyan
        case "PAN_BEFORE_ZOOM": return .orange
        case "ZOOM_OUT": return .purple
        case "NO_SUBJECT": return .gray
        default: return .green
        }
    }
}

/// Optional on-device Tracking Performance Debug HUD (default OFF in Settings -> Bố cục).
/// Observes ONLY `TrackingPerfHUDState` at 4Hz so it never invalidates `CameraMainView`.
public struct TrackingPerfDebugHUDView: View {
    @ObservedObject var perfState: TrackingPerfHUDState

    public init(perfState: TrackingPerfHUDState) {
        self.perfState = perfState
    }

    public var body: some View {
        let s = perfState.snapshot
        VStack(alignment: .trailing, spacing: 2.5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(thermalColor(s.thermalState))
                    .frame(width: 6, height: 6)
                Text("PERF DEBUG")
                    .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Text(String(format: "FPS cam %.0f · UI %.0f · drop %llu", s.cameraFPS, s.overlayFPS, s.droppedFrames))
                .font(.system(size: 8.8, weight: .medium, design: .monospaced))
                .foregroundColor(.green)
            Text(String(format: "F→V p50 %.1f / p95 %.1fms", s.frameToVisionP50Ms, s.frameToVisionP95Ms))
                .font(.system(size: 8.6, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
            Text(String(format: "Trk p50 %.1f / p95 %.1fms", s.visionTrackP50Ms, s.visionTrackP95Ms))
                .font(.system(size: 8.6, weight: .regular, design: .monospaced))
                .foregroundColor(.cyan)
            Text(String(format: "UI  p50 %.1f / p95 %.1fms · blk %.0fms", s.trackToUIP50Ms, s.trackToUIP95Ms, s.mainThreadMaxBlockMs))
                .font(.system(size: 8.6, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
            Text(String(format: "RAM %.0fMB (av %dMB) · %@ · %.2fx", s.memoryPhysMB, s.memoryAvailMB, s.thermalState, s.displayZoom))
                .font(.system(size: 8.6, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.74))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 52)
        .padding(.trailing, 8)
        .allowsHitTesting(false)
    }

    private func thermalColor(_ thermal: String) -> Color {
        switch thermal {
        case "nom": return .green
        case "fair": return .yellow
        case "SERIOUS": return .orange
        default: return .red
        }
    }
}
