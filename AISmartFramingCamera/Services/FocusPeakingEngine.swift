//
//  FocusPeakingEngine.swift
//  AISmartFramingCamera
//
//  Động cơ Focus Peaking Báo Nét Điện Ảnh Chuyên Nghiệp 60 FPS
//  Thuật toán: High-Contrast Sobel + 3x3 Morphological Dilation + Halo Contrast + Triệt Nhiễu ISO
//

import Foundation
import CoreImage
import CoreVideo
import SwiftUI
import Metal

public enum FocusPeakingColor: String, CaseIterable, Identifiable, Sendable {
    case green = "Xanh Lá Neon"
    case yellow = "Vàng Kim"
    case red = "Đỏ Rực"
    case cyan = "Xanh Dương"

    public var id: String { rawValue }

    public var swiftUIColor: Color {
        switch self {
        case .green: return Color(red: 0.15, green: 1.0, blue: 0.35)
        case .yellow: return Color(red: 1.0, green: 0.88, blue: 0.0)
        case .red: return Color(red: 1.0, green: 0.12, blue: 0.28)
        case .cyan: return Color(red: 0.0, green: 1.0, blue: 1.0)
        }
    }

    /// Thành phần màu RGB Neon để phủ cạnh sắc nét
    public var neonComponents: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let v = neonVector
        return (r: CGFloat(v.x), g: CGFloat(v.y), b: CGFloat(v.z))
    }
}

/// Động cơ Focus Peaking Báo Nét Điện Ảnh Chuyên Nghiệp 60 FPS
public final class FocusPeakingEngine: @unchecked Sendable {
    public static let shared = FocusPeakingEngine()

    private let processor = FocusPeakingMetalProcessor.shared
    private let ciContext: CIContext

    public init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [.useSoftwareRenderer: false])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    /// Hòa trộn tia Laser báo nét lên ảnh xem trước 60 FPS trên GPU Metal
    /// Triệt tiêu 100% nhiễu ISO ở các vùng phẳng, làm dày nét 2.5px và tạo Halo Contrast tôn sáng
    public func applyLaserFocusPeaking(to ciImage: CIImage, color: FocusPeakingColor) -> CIImage {
        return processor.processPeaking(inputImage: ciImage, color: color)
    }

    /// Tương thích ngược: Xử lý frame bất đồng bộ nếu có caller cũ
    public func processFrame(ciImage: CIImage, color: FocusPeakingColor, completion: @escaping @Sendable (CGImage?) -> Void) {
        let output = applyLaserFocusPeaking(to: ciImage, color: color)
        let renderRect = output.extent.integral
        if let cg = ciContext.createCGImage(output, from: renderRect) {
            completion(cg)
        } else {
            completion(nil)
        }
    }
}
