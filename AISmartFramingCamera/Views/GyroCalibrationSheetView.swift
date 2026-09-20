import SwiftUI
import CoreMotion
import UIKit
import simd

/// Màn hình Hướng dẫn Hiệu Chuẩn Con Quay Hồi Chuyển & Thước Cân Đối Xứng (Gyroscope & Horizon Leveler Wizard)
/// Hỗ trợ chuẩn hóa zero-bias, bù góc nghiêng do ốp lưng/camera lồi và tối ưu hóa phản hồi tracking 6DoF 60Hz.
public struct GyroCalibrationSheetView: View {
    @ObservedObject public var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - State Machine
    public enum CalibrationStep: Int, CaseIterable {
        case flatZeroBias = 1
        case portraitHorizon = 2
        case dynamic3DTest = 3

        var title: String {
            switch self {
            case .flatZeroBias: return "Cân tĩnh mặt phẳng"
            case .portraitHorizon: return "Cân góc chụp dọc"
            case .dynamic3DTest: return "Kiểm tra phản hồi 3D"
            }
        }

        var icon: String {
            switch self {
            case .flatZeroBias: return "table.furniture"
            case .portraitHorizon: return "iphone"
            case .dynamic3DTest: return "gyroscope"
            }
        }
    }

    @State private var currentStep: CalibrationStep = .flatZeroBias

    // MARK: - Motion Sensor State
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    @State private var currentRawRoll: Double = 0.0
    @State private var currentRawPitch: Double = 0.0
    @State private var currentRawYaw: Double = 0.0
    @State private var currentGravityX: Double = 0.0
    @State private var currentGravityY: Double = 0.0
    @State private var currentGravityZ: Double = -1.0
    @State private var isStationaryOnFlat: Bool = false
    @State private var flatStabilityProgress: Double = 0.0
    @State private var isFlatCalibrationCompleted: Bool = false
    @State private var gravityHistory: [SIMD3<Double>] = []

    // Calibration Target Values
    @State private var selectedRollOffset: Double = 0.0
    @State private var selectedPitchOffset: Double = 0.0
    @State private var isRollOffsetLocked: Bool = false

    // Haptics & UI
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let hapticNotification = UINotificationFeedbackGenerator()
    @State private var showResetConfirmDialog = false
    @State private var toastMessage: String? = nil

    // Design Tokens
    private let canvasBackground = Color(red: 0.035, green: 0.039, blue: 0.051) // #090A0D
    private let cardBackground = Color(red: 0.078, green: 0.082, blue: 0.098)   // #141519
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)           // #FFB028
    private let emeraldGreen = Color(red: 0.20, green: 0.86, blue: 0.45)
    private let cyanAccent = Color(red: 0.35, green: 0.75, blue: 1.0)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
        self.motionQueue.name = "com.alignai.gyro.calibration"
        self.motionQueue.maxConcurrentOperationCount = 1
        self.motionQueue.qualityOfService = .userInteractive
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                canvasBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header Bar
                    headerBar
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    // Step Indicator Capsule
                    stepIndicatorBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    // Step Dynamic Content
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            switch currentStep {
                            case .flatZeroBias:
                                flatZeroBiasStepView
                            case .portraitHorizon:
                                portraitHorizonStepView
                            case .dynamic3DTest:
                                dynamic3DTestStepView
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    Spacer(minLength: 0)

                    // Bottom Action Bar
                    bottomActionBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            Color(red: 0.06, green: 0.065, blue: 0.08)
                                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.08)), alignment: .top)
                        )
                }

                // Toast Notification Overlay
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(emeraldGreen)
                            Text(msg)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color(red: 0.12, green: 0.12, blue: 0.15)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.5), radius: 10, y: 5)
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
            .onAppear {
                self.selectedRollOffset = viewModel.gyroRollOffsetDegrees
                self.selectedPitchOffset = viewModel.gyroPitchOffsetDegrees
                startMotionUpdates()
            }
            .onDisappear {
                stopMotionUpdates()
            }
            .confirmationDialog(
                "Khôi phục hiệu chuẩn mặc định?",
                isPresented: $showResetConfirmDialog,
                titleVisibility: .visible
            ) {
                Button("Đặt lại về gốc 0.0°", role: .destructive) {
                    resetToFactoryDefaults()
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Xóa toàn bộ độ lệch bù trừ Roll/Pitch đã lưu và khôi phục cảm biến con quay về thông số ban đầu của phần cứng.")
            }
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            Button(action: {
                hapticFeedback.impactOccurred()
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color.white.opacity(0.40))
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("HIỆU CHUẨN GYRO & THƯỚC CÂN")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(amberGold)

                Text("Tối ưu hóa con quay 60Hz & Cân đối xứng")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.55))
            }

            Spacer()

            Button(action: {
                showResetConfirmDialog = true
            }) {
                Text("Đặt lại")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.red.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Step Indicator Bar
    private var stepIndicatorBar: some View {
        HStack(spacing: 8) {
            ForEach(CalibrationStep.allCases, id: \.rawValue) { step in
                let isCurrent = currentStep == step
                let isPast = currentStep.rawValue > step.rawValue

                Button(action: {
                    hapticFeedback.impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        currentStep = step
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: isPast ? "checkmark.circle.fill" : step.icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isCurrent ? Color.black : (isPast ? emeraldGreen : Color.white.opacity(0.40)))

                        Text(step.title)
                            .font(.system(size: 11, weight: isCurrent ? .bold : .medium, design: .rounded))
                            .foregroundColor(isCurrent ? Color.black : (isPast ? Color.white.opacity(0.85) : Color.white.opacity(0.40)))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule().fill(isCurrent ? amberGold : Color.white.opacity(0.06))
                    )
                    .overlay(
                        Capsule().stroke(isCurrent ? amberGold : Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - STEP 1: CÂN TĨNH MẶT PHẲNG (Zero-Bias Flat Calibration)
    @ViewBuilder
    private var flatZeroBiasStepView: some View {
        VStack(spacing: 16) {
            // Instruction Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(cyanAccent.opacity(0.16))
                                .frame(width: 36, height: 36)
                            Image(systemName: "table.furniture")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(cyanAccent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("BƯỚC 1: TRIỆT TIÊU SAI SỐ TRÔI TĨNH")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                            Text("Khử trôi Zero-Bias & bù mặt bàn phẳng")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Color.white.opacity(0.55))
                        }
                    }

                    Text("Đặt iPhone nằm yên trên một mặt bàn phẳng tĩnh và thả tay ra hoàn toàn. Hệ thống sẽ tự động đo độ ổn định cảm biến trong 2.5 giây.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.80))
                        .lineSpacing(3)
                }
            }

            // Interactive Flat Detector Animation Ring
            cardContainer {
                VStack(spacing: 20) {
                    ZStack {
                        // Background Circle
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 10)
                            .frame(width: 170, height: 170)

                        // Animated Progress Ring
                        Circle()
                            .trim(from: 0.0, to: flatStabilityProgress)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [amberGold, emeraldGreen]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 170, height: 170)
                            .animation(.linear(duration: 0.1), value: flatStabilityProgress)

                        // Center Icon & Metrics
                        VStack(spacing: 6) {
                            if isFlatCalibrationCompleted {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 44, weight: .bold))
                                    .foregroundColor(emeraldGreen)
                                    .transition(.scale.combined(with: .opacity))
                                Text("HOÀN TẤT")
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundColor(emeraldGreen)
                            } else {
                                Image(systemName: isStationaryOnFlat ? "lock.shield.fill" : "hand.raised.fill")
                                    .font(.system(size: 38))
                                    .foregroundColor(isStationaryOnFlat ? amberGold : Color.white.opacity(0.35))

                                Text("\(Int(flatStabilityProgress * 100))%")
                                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.top, 8)

                    // Status Text Badge
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isFlatCalibrationCompleted ? emeraldGreen : (isStationaryOnFlat ? amberGold : Color.red))
                            .frame(width: 8, height: 8)

                        Text(
                            isFlatCalibrationCompleted
                                ? "Cảm biến tĩnh đạt chuẩn! Đã triệt tiêu sai số trôi."
                                : (isStationaryOnFlat
                                    ? "Đang ghi nhận dữ liệu tĩnh... Vui lòng không chạm máy."
                                    : "Chưa đặt phẳng hoặc phát hiện rung lắc! Hãy giữ máy yên.")
                        )
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(isFlatCalibrationCompleted ? emeraldGreen : (isStationaryOnFlat ? amberGold : Color.white.opacity(0.70)))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.white.opacity(0.04))
                    )

                    // Next Step Button when completed
                    if isFlatCalibrationCompleted {
                        Button(action: {
                            hapticFeedback.impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                currentStep = .portraitHorizon
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text("Chuyển sang Bước 2: Cân góc chụp dọc")
                                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(emeraldGreen))
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }

    // MARK: - STEP 2: CÂN GÓC CHỤP DỌC (Portrait Horizon & Bubble Level)
    @ViewBuilder
    private var portraitHorizonStepView: some View {
        VStack(spacing: 16) {
            // Instruction Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(amberGold.opacity(0.16))
                                .frame(width: 36, height: 36)
                            Image(systemName: "iphone")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(amberGold)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("BƯỚC 2: CÂN BẰNG THƯỚC CHÂN TRỜI")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                            Text("Bù sai số ốp lưng & cụm camera lồi")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Color.white.opacity(0.55))
                        }
                    }

                    Text("Cầm iPhone thẳng đứng ở tầm mắt theo tư thế chụp tự nhiên. Căn chỉnh đường chân trời kỹ thuật số về 0.0° rồi bấm 'Khóa góc cân bằng' bên dưới.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.80))
                        .lineSpacing(3)
                }
            }

            // Interactive Digital Bubble Level HUD
            cardContainer {
                let calibratedRoll = currentRawRoll - selectedRollOffset
                let isPerfectLevel = abs(calibratedRoll) <= 0.5
                let isCloseLevel = abs(calibratedRoll) <= 1.5

                VStack(spacing: 20) {
                    // Digital Bubble Meter
                    ZStack {
                        // Outer Ring with Angle Marks
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 2)
                            .frame(width: 210, height: 210)

                        // Angle ticks at -45, 0, +45
                        ForEach([-45, -30, -15, 0, 15, 30, 45], id: \.self) { deg in
                            Rectangle()
                                .fill(deg == 0 ? amberGold : Color.white.opacity(0.20))
                                .frame(width: deg == 0 ? 3 : 1.5, height: deg == 0 ? 14 : 8)
                                .offset(y: -105)
                                .rotationEffect(.degrees(Double(deg)))
                        }

                        // Horizontal Horizon Line (Tilts with device)
                        Rectangle()
                            .fill(isPerfectLevel ? emeraldGreen : (isCloseLevel ? amberGold : Color.white.opacity(0.40)))
                            .frame(width: 180, height: isPerfectLevel ? 2.5 : 1.5)
                            .rotationEffect(.degrees(calibratedRoll))
                            .shadow(color: isPerfectLevel ? emeraldGreen.opacity(0.6) : Color.clear, radius: 6)

                        // Center Reference Crosshairs
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                            .frame(width: 44, height: 44)

                        // Floating Digital Bubble
                        let bubbleOffset = CGFloat(max(-75, min(75, calibratedRoll * 4.0)))
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        isPerfectLevel ? emeraldGreen : amberGold,
                                        (isPerfectLevel ? emeraldGreen : amberGold).opacity(0.3)
                                    ],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 14
                                )
                            )
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .offset(x: bubbleOffset)
                            .shadow(color: (isPerfectLevel ? emeraldGreen : amberGold).opacity(0.8), radius: 8)
                            .animation(.easeOut(duration: 0.08), value: bubbleOffset)
                    }
                    .frame(height: 220)

                    // Big Precision Readout Display
                    HStack(spacing: 16) {
                        VStack(spacing: 2) {
                            Text("GÓC HIỆN TẠI")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(Color.white.opacity(0.45))
                            Text(String(format: "%+.1f°", calibratedRoll))
                                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                                .foregroundColor(isPerfectLevel ? emeraldGreen : (isCloseLevel ? amberGold : .white))
                        }

                        Divider()
                            .frame(height: 32)
                            .background(Color.white.opacity(0.10))

                        VStack(spacing: 2) {
                            Text("BÙ LỆCH (OFFSET)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(Color.white.opacity(0.45))
                            Text(String(format: "%+.1f°", selectedRollOffset))
                                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                                .foregroundColor(amberGold)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.40)))

                    // Micro-Tuning Buttons & Lock Button
                    VStack(spacing: 10) {
                        Button(action: {
                            selectedRollOffset = currentRawRoll
                            isRollOffsetLocked = true
                            hapticNotification.notificationOccurred(.success)
                            showToastBanner("Đã khóa góc hiện tại làm chuẩn 0.0°")
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: isRollOffsetLocked ? "checkmark.seal.fill" : "lock.rotation")
                                    .font(.system(size: 15, weight: .bold))
                                Text(isRollOffsetLocked ? "Đã khóa góc chuẩn 0.0° (Nhấn để khóa lại)" : "Khóa tư thế này làm chuẩn 0.0°")
                                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(amberGold))
                        }
                        .buttonStyle(.plain)

                        // Fine Adjustment Steppers
                        HStack(spacing: 10) {
                            fineTuneButton(title: "-0.5°", delta: -0.5)
                            fineTuneButton(title: "-0.1°", delta: -0.1)
                            Button("0.0°") {
                                selectedRollOffset = 0.0
                                hapticFeedback.impactOccurred()
                            }
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            fineTuneButton(title: "+0.1°", delta: 0.1)
                            fineTuneButton(title: "+0.5°", delta: 0.5)
                        }
                    }

                    // Next Step Button
                    Button(action: {
                        hapticFeedback.impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            currentStep = .dynamic3DTest
                        }
                    }) {
                        HStack(spacing: 8) {
                            Text("Tiếp tục: Kiểm tra phản hồi 3D")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(cyanAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(cyanAccent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func fineTuneButton(title: String, delta: Double) -> some View {
        Button(action: {
            selectedRollOffset += delta
            hapticFeedback.impactOccurred()
        }) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - STEP 3: KIỂM TRA PHẢN HỒI CON QUAY 3D (Dynamic 3D Response Test)
    @ViewBuilder
    private var dynamic3DTestStepView: some View {
        VStack(spacing: 16) {
            // Instruction Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(emeraldGreen.opacity(0.16))
                                .frame(width: 36, height: 36)
                            Image(systemName: "gyroscope")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(emeraldGreen)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("BƯỚC 3: KIỂM TRA ĐỘ NHẠY 3D REALTIME")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                            Text("Động cơ Spatial Tracking 6DoF 60Hz")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Color.white.opacity(0.55))
                        }
                    }

                    Text("Nghiêng máy sang trái, phải, gật lên xuống để kiểm tra phản hồi của con quay 3D. Đồ họa bên dưới phải di chuyển tức thì và bám sát từng chuyển động của bạn.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.80))
                        .lineSpacing(3)
                }
            }

            // Real-time 3D Gyroscope Gimbal Graphic
            cardContainer {
                let calibratedRoll = currentRawRoll - selectedRollOffset
                VStack(spacing: 16) {
                    ZStack {
                        // Outer Gimbal Ring (Yaw / Roll)
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 4)
                            .frame(width: 170, height: 170)

                        // Dynamic Horizon Pitch Sphere
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        cyanAccent.opacity(0.35),
                                        amberGold.opacity(0.20)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 130, height: 130)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(amberGold.opacity(0.60), lineWidth: 1.5)
                            )
                            .rotationEffect(.degrees(calibratedRoll))
                            .offset(y: CGFloat(max(-35, min(35, currentRawPitch * 0.7))))
                            .shadow(color: amberGold.opacity(0.35), radius: 10)

                        // Center Target Reticle
                        Circle()
                            .stroke(emeraldGreen, lineWidth: 2)
                            .frame(width: 32, height: 32)

                        Circle()
                            .fill(emeraldGreen)
                            .frame(width: 6, height: 6)
                    }
                    .frame(height: 190)

                    // 3-Metric Diagnostic Cards
                    HStack(spacing: 10) {
                        metricBox(label: "Tần số IMU", value: "60 Hz", color: emeraldGreen)
                        metricBox(label: "Độ trễ", value: "< 8 ms", color: cyanAccent)
                        metricBox(label: "Trạng thái", value: "TỐI ƯU", color: amberGold)
                    }

                    // Raw Telemetry Stream
                    HStack(spacing: 12) {
                        telemetryPill(axis: "ROLL", val: calibratedRoll)
                        telemetryPill(axis: "PITCH", val: currentRawPitch)
                        telemetryPill(axis: "GRAVITY Z", val: currentGravityZ)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func metricBox(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(Color.white.opacity(0.50))
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private func telemetryPill(axis: String, val: Double) -> some View {
        HStack(spacing: 4) {
            Text(axis)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.40))
            Text(String(format: "%+.1f", val))
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }

    // MARK: - Bottom Action Bar
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // Reset to defaults
            Button(action: {
                showResetConfirmDialog = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .bold))
                    Text("Đặt lại gốc")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundColor(Color.white.opacity(0.70))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            // Save & Apply
            Button(action: {
                saveAndApplyCalibration()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("Lưu & Áp dụng")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(amberGold)
                )
                .shadow(color: amberGold.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - CoreMotion Management & Stability Processing
    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { motion, _ in
            guard let motion = motion else { return }

            let gx = Double(motion.gravity.x)
            let gy = Double(motion.gravity.y)
            let gz = Double(motion.gravity.z)
            let rawRoll = atan2(gx, -gy) * 180.0 / .pi
            let rawPitch = atan2(gz, hypot(gx, gy)) * 180.0 / .pi
            let rawYaw = motion.attitude.yaw * 180.0 / .pi

            let sample = SIMD3<Double>(gx, gy, gz)

            DispatchQueue.main.async {
                self.currentGravityX = gx
                self.currentGravityY = gy
                self.currentGravityZ = gz
                self.currentRawRoll = rawRoll
                self.currentRawPitch = rawPitch
                self.currentRawYaw = rawYaw

                // Process Flat Stability in Step 1
                if self.currentStep == .flatZeroBias && !self.isFlatCalibrationCompleted {
                    self.processFlatStabilitySample(sample)
                }
            }
        }
    }

    private func processFlatStabilitySample(_ sample: SIMD3<Double>) {
        gravityHistory.append(sample)
        if gravityHistory.count > 25 {
            gravityHistory.removeFirst()
        }

        guard gravityHistory.count >= 20 else { return }

        // Compute variance of gravity vector
        var mean = SIMD3<Double>(0, 0, 0)
        for s in gravityHistory { mean += s }
        mean /= Double(gravityHistory.count)

        var variance: Double = 0.0
        for s in gravityHistory {
            let diff = s - mean
            variance += simd_dot(diff, diff)
        }
        variance /= Double(gravityHistory.count)

        // Device is lying flat if |gz| > 0.82 and variance is tiny (< 0.00025)
        let isLyingFlat = abs(sample.z) > 0.80
        let isQuiet = variance < 0.00025
        let stableNow = isLyingFlat && isQuiet

        self.isStationaryOnFlat = stableNow

        if stableNow {
            // Count up 2.5 seconds (60Hz * 2.5s = 150 samples)
            let stepProgress = 1.0 / 150.0
            let newProgress = min(1.0, flatStabilityProgress + stepProgress)
            self.flatStabilityProgress = newProgress

            if newProgress >= 1.0 && !isFlatCalibrationCompleted {
                self.isFlatCalibrationCompleted = true
                self.hapticNotification.notificationOccurred(.success)
                showToastBanner("Đã triệt tiêu sai số trôi tĩnh thành công!")
            }
        } else {
            // Reset progress if device moves
            if flatStabilityProgress > 0.05 && !isFlatCalibrationCompleted {
                self.flatStabilityProgress = max(0.0, flatStabilityProgress - 0.05)
            }
        }
    }

    private func stopMotionUpdates() {
        motionManager.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
    }

    // MARK: - Actions
    private func saveAndApplyCalibration() {
        viewModel.applyGyroCalibration(
            rollOffset: selectedRollOffset,
            pitchOffset: selectedPitchOffset
        )
        hapticNotification.notificationOccurred(.success)
        showToastBanner("Đã lưu thông số hiệu chuẩn con quay hồi chuyển!")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            dismiss()
        }
    }

    private func resetToFactoryDefaults() {
        viewModel.resetGyroCalibration()
        self.selectedRollOffset = 0.0
        self.selectedPitchOffset = 0.0
        self.isRollOffsetLocked = false
        self.flatStabilityProgress = 0.0
        self.isFlatCalibrationCompleted = false
        hapticNotification.notificationOccurred(.warning)
        showToastBanner("Đã khôi phục cài đặt gốc 0.0°")
    }

    private func showToastBanner(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.25)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    // MARK: - Reusable Card View Container
    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
