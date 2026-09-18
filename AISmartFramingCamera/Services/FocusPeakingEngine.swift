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
        case .green: return Color(red: 0.0, green: 1.0, blue: 0.35)
        case .yellow: return Color(red: 1.0, green: 0.88, blue: 0.0)
        case .red: return Color(red: 1.0, green: 0.2, blue: 0.2)
        case .cyan: return Color(red: 0.0, green: 0.9, blue: 1.0)
        }
    }
    
    // Core Image Color Matrix vectors for neon edge coloring
    var colorMatrixVectors: (r: CIVector, g: CIVector, b: CIVector, a: CIVector, bias: CIVector) {
        switch self {
        case .green:
            return (
                r: CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0),
                g: CIVector(x: 2.0, y: 2.0, z: 2.0, w: 0.0),
                b: CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0.0),
                a: CIVector(x: 3.5, y: 3.5, z: 3.5, w: 0.0),
                bias: CIVector(x: 0.0, y: 0.0, z: 0.0, w: -0.25)
            )
        case .yellow:
            return (
                r: CIVector(x: 2.2, y: 2.2, z: 2.2, w: 0.0),
                g: CIVector(x: 1.9, y: 1.9, z: 1.9, w: 0.0),
                b: CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0),
                a: CIVector(x: 3.5, y: 3.5, z: 3.5, w: 0.0),
                bias: CIVector(x: 0.0, y: 0.0, z: 0.0, w: -0.25)
            )
        case .red:
            return (
                r: CIVector(x: 2.5, y: 2.5, z: 2.5, w: 0.0),
                g: CIVector(x: 0.1, y: 0.1, z: 0.1, w: 0.0),
                b: CIVector(x: 0.1, y: 0.1, z: 0.1, w: 0.0),
                a: CIVector(x: 3.5, y: 3.5, z: 3.5, w: 0.0),
                bias: CIVector(x: 0.0, y: 0.0, z: 0.0, w: -0.25)
            )
        case .cyan:
            return (
                r: CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0),
                g: CIVector(x: 2.0, y: 2.0, z: 2.0, w: 0.0),
                b: CIVector(x: 2.5, y: 2.5, z: 2.5, w: 0.0),
                a: CIVector(x: 3.5, y: 3.5, z: 3.5, w: 0.0),
                bias: CIVector(x: 0.0, y: 0.0, z: 0.0, w: -0.25)
            )
        }
    }
}

/// Động cơ Focus Peaking Báo Nét Điện Ảnh Chuyên Nghiệp
/// Thuật toán Sobel Edge Detection + High-pass Frequency Isolation gia tốc phần cứng trên GPU Metal.
public final class FocusPeakingEngine: @unchecked Sendable {
    public static let shared = FocusPeakingEngine()
    
    private let processingQueue = DispatchQueue(label: "com.alignai.focusPeakingQueue", qos: .userInteractive)
    private let ciContext: CIContext
    private let stateLock = NSLock()
    private var isProcessing = false
    
    public init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [.useSoftwareRenderer: false])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }
    
    /// Xử lý khung hình CIImage và trả về ảnh viền nét mờ trong suốt (Không bao giờ ghi đè nil khi drop frame)
    public func processFrame(ciImage: CIImage, color: FocusPeakingColor, completion: @escaping @Sendable (CGImage?) -> Void) {
        stateLock.lock()
        guard !isProcessing else { stateLock.unlock(); return }
        isProcessing = true
        stateLock.unlock()
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.isProcessing = false
                self.stateLock.unlock()
            }
            
            // 1. Downscale tối ưu để tăng tốc độ xử lý GPU lên 60FPS
            let width = ciImage.extent.width
            let height = ciImage.extent.height
            guard width > 0, height > 0 else { return }
            let targetWidth: CGFloat = 720.0
            let scale = width > targetWidth ? targetWidth / width : 1.0
            let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let renderRect = CGRect(origin: .zero, size: CGSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
            
            // 2. Chuyển đổi đơn sắc và tăng tương phản tần số cao
            guard let colorControls = CIFilter(name: "CIColorControls") else { return }
            colorControls.setValue(scaledImage, forKey: kCIInputImageKey)
            colorControls.setValue(0.0, forKey: kCIInputSaturationKey)
            colorControls.setValue(1.8, forKey: kCIInputContrastKey)
            guard let monoImage = colorControls.outputImage else { return }
            
            // 3. Phát hiện biên cạnh độ tương phản cao (Sobel Edge Detection) với cường độ cao
            guard let edgesFilter = CIFilter(name: "CIEdges") else { return }
            edgesFilter.setValue(monoImage, forKey: kCIInputImageKey)
            edgesFilter.setValue(10.0, forKey: "inputIntensity")
            guard let edgeOutput = edgesFilter.outputImage else { return }
            
            // 4. Phủ màu Neon và triệt tiêu vùng nền đen (Transparent Alpha Masking)
            guard let colorMatrixFilter = CIFilter(name: "CIColorMatrix") else { return }
            let vectors = color.colorMatrixVectors
            colorMatrixFilter.setValue(edgeOutput, forKey: kCIInputImageKey)
            colorMatrixFilter.setValue(vectors.r, forKey: "inputRVector")
            colorMatrixFilter.setValue(vectors.g, forKey: "inputGVector")
            colorMatrixFilter.setValue(vectors.b, forKey: "inputBVector")
            colorMatrixFilter.setValue(vectors.a, forKey: "inputAVector")
            colorMatrixFilter.setValue(vectors.bias, forKey: "inputBiasVector")
            guard let matrixOutput = colorMatrixFilter.outputImage else { return }
            
            // CẮT BỎ VÙNG VÔ HẠN: Do inputBiasVector có giá trị âm (-0.25), CoreImage đánh dấu extent là CGRect.infinite.
            // Phải crop về renderRect hữu hạn thì ciContext.createCGImage mới thành công!
            let finalOutput = matrixOutput.cropped(to: renderRect)
            
            // 5. Kết xuất CGImage GPU siêu tốc
            if let cgImage = self.ciContext.createCGImage(finalOutput, from: renderRect) {
                completion(cgImage)
            }
        }
    }
}
