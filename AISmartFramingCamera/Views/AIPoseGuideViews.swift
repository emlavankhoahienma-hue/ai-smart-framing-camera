import SwiftUI
import CoreGraphics

// MARK: - Pose Wireframe View (Lớp Vẽ Khung Xương Neon Hướng Dẫn)
public struct PoseWireframeView: View {
    let template: AIPoseTemplate
    let liveJoints: [AIPoseJoint: CGPoint]
    let isMatched: Bool
    let size: CGSize

    public init(
        template: AIPoseTemplate,
        liveJoints: [AIPoseJoint: CGPoint] = [:],
        isMatched: Bool,
        size: CGSize
    ) {
        self.template = template
        self.liveJoints = liveJoints
        self.isMatched = isMatched
        self.size = size
    }

    public var body: some View {
        ZStack {
            // 1. Vẽ các đường xương nối (Bones) của Template
            Canvas { context, canvasSize in
                let strokeColor = isMatched
                    ? Color(red: 0.06, green: 0.85, blue: 0.45).opacity(0.92)
                    : Color(red: 0.06, green: 0.91, blue: 1.00).opacity(0.68)
                let strokeWidth: CGFloat = isMatched ? 2.6 : 1.8

                for bone in AIPoseBone.standardConnections {
                    guard let ptFrom = template.keypoints[bone.from],
                          let ptTo = template.keypoints[bone.to] else {
                        continue
                    }
                    let p1 = CGPoint(x: ptFrom.x * canvasSize.width, y: ptFrom.y * canvasSize.height)
                    let p2 = CGPoint(x: ptTo.x * canvasSize.width, y: ptTo.y * canvasSize.height)

                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)

                    context.stroke(
                        path,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                    )
                }

                // Vẽ các khớp nối (Joints)
                let jointColor = isMatched ? Color.white : Color(red: 0.95, green: 0.88, blue: 0.50)
                let jointRadius: CGFloat = isMatched ? 4.5 : 3.2

                for ptNorm in template.keypoints.values {
                    let center = CGPoint(x: ptNorm.x * canvasSize.width, y: ptNorm.y * canvasSize.height)
                    let rect = CGRect(
                        x: center.x - jointRadius,
                        y: center.y - jointRadius,
                        width: jointRadius * 2,
                        height: jointRadius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(jointColor))
                }
            }
            .shadow(
                color: isMatched
                    ? Color(red: 0.06, green: 0.85, blue: 0.45).opacity(0.8)
                    : Color(red: 0.06, green: 0.91, blue: 1.00).opacity(0.4),
                radius: isMatched ? 10 : 4
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isMatched)

            // 2. Vòng tròn đầu (Head Guide Circle)
            if let nose = template.keypoints[.nose] {
                let center = CGPoint(x: nose.x * size.width, y: nose.y * size.height)
                Circle()
                    .stroke(
                        isMatched
                            ? Color(red: 0.06, green: 0.85, blue: 0.45)
                            : Color(red: 0.06, green: 0.91, blue: 1.00).opacity(0.7),
                        lineWidth: isMatched ? 2.2 : 1.5
                    )
                    .frame(width: size.width * 0.14, height: size.width * 0.14)
                    .position(center)
                    .shadow(
                        color: isMatched ? Color.green.opacity(0.8) : Color.cyan.opacity(0.4),
                        radius: isMatched ? 8 : 3
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pose Guide HUD Card (Thẻ Thông Báo Tiến Trình Tạo Dáng)
public struct PoseGuideHUDCard: View {
    let template: AIPoseTemplate
    let score: Double
    let isMatched: Bool
    let onClose: () -> Void

    public init(
        template: AIPoseTemplate,
        score: Double,
        isMatched: Bool,
        onClose: @escaping () -> Void
    ) {
        self.template = template
        self.score = score
        self.isMatched = isMatched
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Icon trạng thái
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
                    .frame(width: 38, height: 38)

                Circle()
                    .trim(from: 0, to: CGFloat(score))
                    .stroke(
                        isMatched ? Color(red: 0.06, green: 0.85, blue: 0.45) : Color(red: 0.06, green: 0.91, blue: 1.00),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 38, height: 38)
                    .animation(.linear(duration: 0.15), value: score)

                Text("\(Int(score * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(isMatched ? Color(red: 0.06, green: 0.85, blue: 0.45) : .white)
            }

            // Thông tin tư thế & quy tắc
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(template.compositionRule)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isMatched ? Color(red: 0.06, green: 0.85, blue: 0.45) : Color.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Nút đóng
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            isMatched
                                ? Color(red: 0.06, green: 0.85, blue: 0.45).opacity(0.6)
                                : Color.white.opacity(0.15),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
    }
}

// MARK: - AI Pose Picker Bottom Sheet (Khay Chọn 48 Dáng Tạo Mẫu)
public struct AIPosePickerBottomSheet: View {
    @Binding var selectedCategory: AIPoseCategory
    @Binding var activeTemplate: AIPoseTemplate?
    @Binding var isPresented: Bool

    public init(
        selectedCategory: Binding<AIPoseCategory>,
        activeTemplate: Binding<AIPoseTemplate?>,
        isPresented: Binding<Bool>
    ) {
        self._selectedCategory = selectedCategory
        self._activeTemplate = activeTemplate
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Thanh gạt (Drag indicator)
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            // Tiêu đề & nút tắt
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk.motion")
                        .foregroundColor(Color(red: 0.06, green: 0.91, blue: 1.00))
                    Text("AI Pose Guide (48 Tư Thế Bố Cục)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)

            // Segmented Category Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AIPoseCategory.allCases) { cat in
                        let isSelected = selectedCategory == cat
                        Button(action: {
                            selectedCategory = cat
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: cat.iconName)
                                    .font(.system(size: 11))
                                Text(cat.rawValue)
                                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color(red: 0.06, green: 0.91, blue: 1.00) : Color.white.opacity(0.10))
                            )
                            .foregroundColor(isSelected ? .black : .white)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // Danh sách các tư thế trong nhóm đã chọn
            let currentTemplates = AIPoseCatalog.templates(for: selectedCategory)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(currentTemplates) { t in
                        let isChosen = activeTemplate?.id == t.id
                        Button(action: {
                            if isChosen {
                                activeTemplate = nil
                            } else {
                                activeTemplate = t
                            }
                        }) {
                            VStack(spacing: 6) {
                                // Thumbnail / Wireframe Preview Box
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(width: 88, height: 116)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(
                                                    isChosen ? Color(red: 0.06, green: 0.91, blue: 1.00) : Color.white.opacity(0.12),
                                                    lineWidth: isChosen ? 2 : 1
                                                )
                                        )

                                    // Mini Wireframe Preview
                                    MiniSkeletonPreview(keypoints: t.keypoints)
                                        .frame(width: 76, height: 104)

                                    if isChosen {
                                        VStack {
                                            HStack {
                                                Spacer()
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(Color(red: 0.06, green: 0.91, blue: 1.00))
                                                    .font(.system(size: 16))
                                                    .padding(6)
                                            }
                                            Spacer()
                                        }
                                        .frame(width: 88, height: 116)
                                    }
                                }

                                Text(t.title)
                                    .font(.system(size: 11, weight: isChosen ? .bold : .regular))
                                    .foregroundColor(isChosen ? Color(red: 0.06, green: 0.91, blue: 1.00) : .white)
                                    .frame(width: 88)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(height: 154)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.96))
                .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: -6)
        )
    }
}

// MARK: - Mini Skeleton Preview
private struct MiniSkeletonPreview: View {
    let keypoints: [AIPoseJoint: CGPoint]

    var body: some View {
        Canvas { context, size in
            let strokeColor = Color(red: 0.06, green: 0.91, blue: 1.00).opacity(0.75)
            for bone in AIPoseBone.standardConnections {
                guard let p1Norm = keypoints[bone.from],
                      let p2Norm = keypoints[bone.to] else { continue }
                let p1 = CGPoint(x: p1Norm.x * size.width, y: p1Norm.y * size.height)
                let p2 = CGPoint(x: p2Norm.x * size.width, y: p2Norm.y * size.height)

                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(strokeColor), lineWidth: 1.2)
            }
            for pt in keypoints.values {
                let c = CGPoint(x: pt.x * size.width, y: pt.y * size.height)
                let r = CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)
                context.fill(Path(ellipseIn: r), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }
}
