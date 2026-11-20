import Foundation

/// Danh sách các tính năng camera chịu kiểm soát điều kiện khả dụng (Capability Gating)
public enum CameraFeature: String, CaseIterable, Sendable {
    case aiComposition
    case livePhoto
    case ultraSharp
    case photoFormat
    case captureTimer
    case horizonLeveler
    case horizonLock
    case dualCamera
    case windowedZoom
    case aspectRatio
    case flash
    case cameraFlip
    case masterWatermark
    case videoQualityAndCodec
    case filmColor
    case focusPeaking
    case proPhoto
}

/// Trạng thái khả dụng của một tính năng: cho phép bật hay bị khóa kèm điều kiện rõ ràng
public enum FeatureAvailability: Equatable, Sendable {
    case available
    case disabled(shortHint: String, detailReason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var shortHint: String? {
        if case .disabled(let hint, _) = self { return hint }
        return nil
    }

    public var detailReason: String? {
        if case .disabled(_, let reason) = self { return reason }
        return nil
    }
}

/// Ảnh chụp trạng thái camera dùng làm đầu vào thuần túy (pure function) để kiểm tra điều kiện
public struct CameraFeatureContext: Equatable, Sendable {
    public var isVideo: Bool
    public var isRecordingVideo: Bool
    public var isFrontCamera: Bool
    public var isDualCameraActive: Bool
    public var isDualCameraSupported: Bool
    public var isUltraSharpEnabled: Bool
    public var isWindowedZoomActive: Bool
    public var isHorizonLockEnabled: Bool
    public var isAISessionActive: Bool
    public var selectedPhotoFormat: PhotoSaveFormat
    public var canSwitchCamera: Bool

    public init(
        isVideo: Bool,
        isRecordingVideo: Bool,
        isFrontCamera: Bool,
        isDualCameraActive: Bool,
        isDualCameraSupported: Bool,
        isUltraSharpEnabled: Bool,
        isWindowedZoomActive: Bool,
        isHorizonLockEnabled: Bool,
        isAISessionActive: Bool,
        selectedPhotoFormat: PhotoSaveFormat,
        canSwitchCamera: Bool
    ) {
        self.isVideo = isVideo
        self.isRecordingVideo = isRecordingVideo
        self.isFrontCamera = isFrontCamera
        self.isDualCameraActive = isDualCameraActive
        self.isDualCameraSupported = isDualCameraSupported
        self.isUltraSharpEnabled = isUltraSharpEnabled
        self.isWindowedZoomActive = isWindowedZoomActive
        self.isHorizonLockEnabled = isHorizonLockEnabled
        self.isAISessionActive = isAISessionActive
        self.selectedPhotoFormat = selectedPhotoFormat
        self.canSwitchCamera = canSwitchCamera
    }
}

/// Bộ kiểm tra điều kiện khả dụng tập trung — một nguồn chân lý duy nhất cho Top Bar, Bảng 6 chấm, Bottom Deck & Cài đặt
public enum CameraFeatureGate {
    public static func availability(for feature: CameraFeature, in ctx: CameraFeatureContext) -> FeatureAvailability {
        switch feature {
        case .aiComposition:
            if ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Ảnh", detailReason: "AI Bố cục chỉ hỗ trợ chế độ Ảnh")
            }
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để dùng AI Bố cục")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Đang quay", detailReason: "Dừng quay video để dùng AI Bố cục")
            }
            return .available

        case .livePhoto:
            if ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Ảnh", detailReason: "Live Photo chỉ hỗ trợ chế độ Ảnh")
            }
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để bật Live Photo")
            }
            if ctx.selectedPhotoFormat == .dng {
                return .disabled(shortHint: "Không dùng RAW", detailReason: "Đổi khỏi RAW DNG để bật Live Photo")
            }
            if ctx.isUltraSharpEnabled {
                return .disabled(shortHint: "Tắt Ultra Sharp", detailReason: "Tắt Ultra Sharp để bật Live Photo")
            }
            return .available

        case .ultraSharp:
            if ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Ảnh", detailReason: "Ultra Sharp chỉ hỗ trợ chế độ Ảnh")
            }
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để bật Ultra Sharp")
            }
            if ctx.isFrontCamera {
                return .disabled(shortHint: "Cần Cam sau", detailReason: "Chuyển sang Camera sau để bật Ultra Sharp")
            }
            if ctx.selectedPhotoFormat == .dng {
                return .disabled(shortHint: "Đổi khỏi RAW", detailReason: "Đổi định dạng khỏi RAW DNG để bật Ultra Sharp")
            }
            return .available

        case .photoFormat:
            if ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Ảnh", detailReason: "Định dạng ảnh chỉ áp dụng ở chế độ Ảnh")
            }
            return .available

        case .captureTimer:
            if ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Ảnh", detailReason: "Hẹn giờ chụp chỉ hỗ trợ chế độ Ảnh")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Đang quay", detailReason: "Không thể đổi hẹn giờ khi đang quay")
            }
            return .available

        case .horizonLeveler:
            if ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Ảnh", detailReason: "Thước cân bằng chỉ hiển thị ở chế độ Ảnh")
            }
            if ctx.isAISessionActive {
                return .disabled(shortHint: "Đang chạy AI", detailReason: "Tắt AI Bố cục để bật/tắt thước cân bằng")
            }
            return .available

        case .horizonLock:
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Dừng quay", detailReason: "Dừng quay video để bật/tắt Khóa chân trời")
            }
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để bật Khóa chân trời 360°")
            }
            if ctx.isWindowedZoomActive {
                return .disabled(shortHint: "Tắt Zoom khung", detailReason: "Tắt Windowed Zoom để bật Khóa chân trời 360°")
            }
            return .available

        case .dualCamera:
            if !ctx.isDualCameraSupported {
                return .disabled(shortHint: "Không hỗ trợ", detailReason: "Thiết bị không hỗ trợ quay chụp MultiCam")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Dừng quay", detailReason: "Dừng quay video để bật/tắt Dual Cam")
            }
            if !ctx.isDualCameraActive {
                if ctx.isWindowedZoomActive {
                    return .disabled(shortHint: "Tắt Zoom khung", detailReason: "Tắt Windowed Zoom trước khi bật Dual Cam")
                }
                if ctx.isUltraSharpEnabled && !ctx.isVideo {
                    return .disabled(shortHint: "Tắt Ultra Sharp", detailReason: "Tắt Ultra Sharp trước khi bật Dual Cam")
                }
                if ctx.isHorizonLockEnabled {
                    return .disabled(shortHint: "Tắt Chân trời", detailReason: "Tắt Khóa chân trời trước khi bật Dual Cam")
                }
            }
            return .available

        case .windowedZoom:
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để dùng Windowed Zoom")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Dừng quay", detailReason: "Dừng quay để bật/tắt chế độ khung cửa sổ")
            }
            return .available

        case .aspectRatio:
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để đổi tỷ lệ khung")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Dừng quay", detailReason: "Dừng quay video để đổi tỷ lệ khung")
            }
            return .available

        case .flash:
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Đèn Flash không khả dụng khi bật Dual Cam")
            }
            if ctx.isVideo && ctx.isFrontCamera {
                return .disabled(shortHint: "Cần Cam sau", detailReason: "Camera trước không có đèn LED khi quay video")
            }
            return .available

        case .cameraFlip:
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Đang quay", detailReason: "Dừng quay video để đổi camera")
            }
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để đổi camera")
            }
            if !ctx.canSwitchCamera {
                return .disabled(shortHint: "Đang xử lý", detailReason: "Vui lòng đợi thao tác camera hoàn tất")
            }
            return .available

        case .masterWatermark:
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Dừng quay", detailReason: "Dừng quay video để bật/tắt Khung Master")
            }
            if !ctx.isVideo && ctx.selectedPhotoFormat == .dng {
                return .disabled(shortHint: "Không dùng RAW", detailReason: "Khung Master không áp dụng cho file RAW DNG")
            }
            if ctx.isVideo && ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để dùng Khung Master cho Video")
            }
            return .available

        case .videoQualityAndCodec:
            if !ctx.isVideo {
                return .disabled(shortHint: "Chỉ chế độ Video", detailReason: "Tùy chọn này chỉ dùng ở chế độ Video")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Đang quay", detailReason: "Dừng quay để đổi độ phân giải / chuẩn nén")
            }
            return .available

        case .filmColor:
            if !ctx.isVideo && ctx.selectedPhotoFormat == .dng {
                return .disabled(shortHint: "Không dùng RAW", detailReason: "File RAW DNG giữ màu cảm biến nguyên bản")
            }
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Đang quay", detailReason: "Dừng quay video để đổi bộ lọc màu")
            }
            return .available

        case .focusPeaking:
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để bật Focus Peaking")
            }
            return .available

        case .proPhoto:
            if ctx.isRecordingVideo {
                return .disabled(shortHint: "Đang quay", detailReason: "Dừng quay video để chuyển sang chế độ Chụp ảnh Pro")
            }
            if ctx.isDualCameraActive {
                return .disabled(shortHint: "Tắt Dual Cam", detailReason: "Tắt Dual Cam để dùng chế độ Chụp ảnh Pro")
            }
            return .available
        }
    }
}
