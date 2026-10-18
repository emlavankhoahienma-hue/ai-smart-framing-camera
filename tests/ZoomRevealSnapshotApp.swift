// Simulator-only visual host. The lens values below are simulated input;
// the reticle, crop geometry, aspect-fill mapping and overlay are production code.
import SwiftUI

@main
struct ZoomRevealSnapshotApp: App {
    var body: some Scene {
        WindowGroup { ZoomRevealSnapshot().preferredColorScheme(.dark) }
    }
}

private struct ZoomRevealSnapshot: View {
    @State private var start = Date()
    @State private var stage = "guide"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: stage != "motion")) { clock in
            let time = max(0, clock.date.timeIntervalSince(start)).truncatingRemainder(dividingBy: 10)
            let sample = sample(at: time)
            GeometryReader { proxy in
                let width = min(proxy.size.width - 24, (proxy.size.height - 130) * 0.75)
                let height = width / 0.75
                VStack(spacing: 16) {
                    Text("ALIGN AI · VIEWFINDER")
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2)
                    ZStack {
                        ArchitectureCalibrationScene()
                            .scaleEffect(sample.zoom)
                        CompositionGridLines(rule: .ruleOfThirds, size: CGSize(width: width, height: height)).opacity(0.2)
                        if !sample.reveal {
                            let centre = CGPoint(x: width / 2, y: height / 2)
                            let target = sample.aligned ? centre : CGPoint(x: width * 0.64, y: height * 0.42)
                            GuidanceRayLine(from: centre, to: target, distance: sample.aligned ? 0 : 0.2)
                            TargetCircleView(isAligned: sample.aligned,
                                trackingQuality: stage == "lost" ? .lost : .locked)
                                .position(target)
                            CurrentCenterCrosshair(isAligned: sample.aligned).position(centre)
                        }
                        ZoomRevealOverlay(
                            geometry: sample.reveal ? ZoomRevealGeometry(startZoom: sample.outward ? 2.4 : 1,
                                targetZoom: sample.outward ? 1 : 2.4) : nil,
                            actualZoom: sample.zoom, bufferAspect: 0.75,
                            isRamping: sample.ramping, revealOpacity: 1)
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(sample.title).font(.system(size: 14, weight: .medium))
                    Text("Kiểm tra giao diện · Zoom mô phỏng")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(Color(red: 1, green: 0, blue: 1))
                .frame(width: 18, height: 18)
        }
        .onAppear { start = Date() }
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            refreshSnapshotStage()
        }
    }

    private func refreshSnapshotStage() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let request = directory.appendingPathComponent("snapshot-stage.txt")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        do {
            let value = try String(contentsOf: request, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["guide", "aligned", "preview", "ramp", "verify", "zoomout", "lost", "motion"].contains(value) else { return }
            if stage != value {
                start = Date()
                stage = value
            }
            let acknowledgement = directory.appendingPathComponent("snapshot-ack.txt")
            var acknowledged = ""
            if FileManager.default.fileExists(atPath: acknowledgement.path) {
                acknowledged = try String(contentsOf: acknowledgement, encoding: .utf8)
            }
            if acknowledged != value {
                try value.write(to: acknowledgement, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Zoom snapshot stage exchange failed: %@", String(describing: error))
        }
    }

    private struct Sample {
        var zoom: CGFloat = 1
        var aligned = false
        var reveal = false
        var ramping = false
        var outward = false
        var title = "Đưa chấm trắng vào vòng giữa"
    }

    private func sample(at time: Double) -> Sample {
        let phase: String
        if stage == "motion" {
            phase = time < 1.8 ? "guide" : time < 2.4 ? "aligned" : time < 3 ? "preview" :
                time < 4.5 ? "ramp" : time < 5 ? "verify" : time < 6.5 ? "done" : time < 8 ? "zoomout" : "guide"
        } else { phase = stage }
        switch phase {
        case "aligned": return Sample(aligned: true, title: "Đã khớp · Giữ máy ổn định")
        case "preview": return Sample(reveal: true, title: "Vùng ảnh sẽ chụp trước khi zoom")
        case "ramp":
            let progress = stage == "motion" ? CGFloat((time - 3) / 1.5) : 0.5
            return Sample(zoom: 1 + 1.4 * progress, reveal: true, ramping: true,
                title: "Viền khung đi theo mức zoom thực")
        case "verify": return Sample(zoom: 2.4, reveal: true, ramping: true, title: "Zoom tới đích · Xác nhận trước khi chụp")
        case "done": return Sample(zoom: 2.4, aligned: true, title: "Đã xác nhận khung chụp")
        case "zoomout":
            let progress = stage == "motion" ? CGFloat((time - 6.5) / 1.5) : 0.5
            return Sample(zoom: 2.4 - 1.4 * progress, reveal: true, ramping: true, outward: true,
                title: "Zoom ra · Thấy thêm không gian xung quanh")
        case "lost": return Sample(title: "Mất dấu · Giữ đúng vị trí đích, báo trạng thái riêng")
        default: return Sample()
        }
    }
}

private struct ArchitectureCalibrationScene: View {
    var body: some View {
        Canvas { context, size in
            let sky = Path(CGRect(origin: .zero, size: size))
            context.fill(sky, with: .linearGradient(Gradient(colors: [Color(red: 0.25, green: 0.48, blue: 0.69),
                Color(red: 0.70, green: 0.76, blue: 0.77)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let ground = CGRect(x: 0, y: size.height * 0.65, width: size.width, height: size.height * 0.35)
            context.fill(Path(ground), with: .color(Color(white: 0.37)))
            let wall = CGRect(x: 0, y: size.height * 0.59, width: size.width, height: size.height * 0.08)
            context.fill(Path(wall), with: .color(Color(red: 0.66, green: 0.47, blue: 0.23)))
            for level in 0..<6 {
                let width = size.width * (0.19 - CGFloat(level) * 0.018)
                let y = size.height * (0.59 - CGFloat(level) * 0.043)
                let block = CGRect(x: size.width / 2 - width / 2, y: y - size.height * 0.03,
                    width: width, height: size.height * 0.04)
                context.fill(Path(block), with: .color(Color(white: 0.27)))
                var roof = Path()
                roof.move(to: CGPoint(x: block.minX - 7, y: block.minY))
                roof.addLine(to: CGPoint(x: block.midX, y: block.minY - size.height * 0.023))
                roof.addLine(to: CGPoint(x: block.maxX + 7, y: block.minY))
                roof.closeSubpath()
                context.fill(roof, with: .color(Color(white: 0.12)))
            }
            for index in 0..<6 {
                var paving = Path()
                paving.move(to: CGPoint(x: size.width / 2, y: size.height * 0.67))
                paving.addLine(to: CGPoint(x: CGFloat(index) * size.width / 5, y: size.height))
                context.stroke(paving, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
            for index in 0..<5 {
                let rect = CGRect(x: size.width * 0.77 + CGFloat(index % 2) * 14,
                    y: size.height * 0.08 + CGFloat(index) * size.height * 0.07,
                    width: size.width * 0.31, height: size.height * 0.19)
                context.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.16, green: 0.28, blue: 0.16)))
            }
        }
    }
}
