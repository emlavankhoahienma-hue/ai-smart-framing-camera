//
//  FocusPeakingEngine.swift
//  AISmartFramingCamera
//
//  Động cơ Focus Peaking Báo Nét Điện Ảnh Chuyên Nghiệp (Thuần Metal Compute 60 FPS)
//  Thuật toán: Fused Dual-Scale Scharr + Re-Blur Defocus Ratio + GPU Histogram EMA + Directional NMS
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

    /// Vector màu sắc Neon chuẩn SIMD3<Float>
    public var neonVector: SIMD3<Float> {
        switch self {
        case .cyan:
            return SIMD3<Float>(0.0, 1.0, 1.0)       // Electric Cyan
        case .red:
            return SIMD3<Float>(1.0, 0.12, 0.28)     // Neon Red
        case .yellow:
            return SIMD3<Float>(1.0, 0.88, 0.0)      // Cyber Yellow
        case .green:
            return SIMD3<Float>(0.15, 1.0, 0.35)     // Matrix Green
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

    public init() {}

    /// Thực thi toàn bộ chuỗi thuật toán Focus Peaking trên GPU Metal và hòa trộn trực tiếp lên Preview Texture
    public func renderFocusPeaking(
        sourcePixelBuffer: CVPixelBuffer?,
        sourceTexture: MTLTexture?,
        targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        color: FocusPeakingColor,
        sensitivity: Float,
        iso: Float,
        displayScale: Float = 2.0
    ) {
        let v = color.neonVector
        processor.renderFocusPeaking(
            sourcePixelBuffer: sourcePixelBuffer,
            sourceTexture: sourceTexture,
            targetTexture: targetTexture,
            commandBuffer: commandBuffer,
            color: (r: v.x, g: v.y, b: v.z, a: 0.90),
            sensitivity: sensitivity,
            iso: iso,
            displayScale: displayScale
        )
    }

    /// Tương thích ngược an toàn cho các caller CoreImage cũ
    public func applyLaserFocusPeaking(to ciImage: CIImage, color: FocusPeakingColor) -> CIImage {
        return ciImage
    }

    /// Tương thích ngược: Xử lý frame bất đồng bộ nếu có caller cũ
    public func processFrame(ciImage: CIImage, color: FocusPeakingColor, completion: @escaping @Sendable (CGImage?) -> Void) {
        completion(nil)
    }
}
