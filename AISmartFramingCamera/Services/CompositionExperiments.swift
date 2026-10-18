import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CoreML
import QuartzCore
import simd

/// Cac ham do va ghi log thuc nghiem tren may that A, B, C, D de xac thuc phan cung va he toa do.
/// Ket qua duoc dinh dang ro rang de nguoi dung sao chep gui lai cho AI phan tich.
public enum CompositionExperiments {

    // MARK: - Thuc nghiem A: Do Ground Truth Toa do (Face Bounding Box IoU)
    public struct ExperimentReportA {
        public let timestamp: TimeInterval
        public let zoomFactor: Double
        public let appleFaceRect: CGRect
        public let visionFaceRect: CGRect?
        public let yoloFaceRect: CGRect?
        public let iouVisionApple: Double
        public let iouYOLOApple: Double

        public var formattedLog: String {
            return """
            [THUC NGHIEM A] Face Bounding Box Ground Truth
            Timestamp: \(String(format: "%.3f", timestamp)) | Zoom: \(String(format: "%.2fx", zoomFactor))
            Apple Face Rect (layer):  \(appleFaceRect)
            Vision Face Rect (layer): \(visionFaceRect.map { "\($0)" } ?? "nil")
            YOLO Face Rect (layer):   \(yoloFaceRect.map { "\($0)" } ?? "nil")
            IoU(Vision, Apple):       \(String(format: "%.4f", iouVisionApple))
            IoU(YOLO, Apple):         \(String(format: "%.4f", iouYOLOApple))
            ------------------------------------------------------------
            """
        }
    }

    public static func computeIoU(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0.0 }
        let interArea = Double(intersection.width * intersection.height)
        let unionArea = Double(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? (interArea / unionArea) : 0.0
    }

    public static func logExperimentA(
        appleFace: CGRect,
        visionFace: CGRect?,
        yoloFace: CGRect?,
        zoom: Double
    ) {
        guard CompositionTuning.isExperimentLoggingEnabled else { return }
        let iouVision = visionFace.map { computeIoU(appleFace, $0) } ?? 0.0
        let iouYOLO = yoloFace.map { computeIoU(appleFace, $0) } ?? 0.0
        let report = ExperimentReportA(
            timestamp: CACurrentMediaTime(),
            zoomFactor: zoom,
            appleFaceRect: appleFace,
            visionFaceRect: visionFace,
            yoloFaceRect: yoloFace,
            iouVisionApple: iouVision,
            iouYOLOApple: iouYOLO
        )
        CameraLogger.info(report.formattedLog, category: .ai)
    }

    // MARK: - Thuc nghiem B: Chieu Quaternion Gyro & Trong luc
    public struct ExperimentReportB {
        public let timestamp: TimeInterval
        public let rawGravity: SIMD3<Double>
        public let qActGravity: SIMD3<Double>
        public let qInverseActGravity: SIMD3<Double>
        public let isDeviceToWorldConsistent: Bool

        public var formattedLog: String {
            return """
            [THUC NGHIEM B] Gyro Quaternion & Gravity Direction
            Timestamp: \(String(format: "%.3f", timestamp))
            Raw Device Gravity:     (\(String(format: "%.3f, %.3f, %.3f", rawGravity.x, rawGravity.y, rawGravity.z)))
            q.act(gravity):         (\(String(format: "%.3f, %.3f, %.3f", qActGravity.x, qActGravity.y, qActGravity.z)))
            q.inverse.act(gravity): (\(String(format: "%.3f, %.3f, %.3f", qInverseActGravity.x, qInverseActGravity.y, qInverseActGravity.z)))
            Ket luan huong Pose:   \(isDeviceToWorldConsistent ? "q la Device -> World chuan" : "Can dao nguoc pose!")
            ------------------------------------------------------------
            """
        }
    }

    public static func logExperimentB(pose: simd_quatd, gravity: SIMD3<Double>) {
        guard CompositionTuning.isExperimentLoggingEnabled else { return }
        let normG = simd_normalize(gravity)
        let qAct = pose.act(normG)
        let qInvAct = pose.inverse.act(normG)
        // Khi may dung yen dung thang dung (rear camera), gravity the gioi la (0, -1, 0) hoac (0, 0, -1) tuy toa do
        let isDeviceToWorld = abs(qAct.z + 1.0) < 0.25 || abs(qAct.y + 1.0) < 0.25
        let report = ExperimentReportB(
            timestamp: CACurrentMediaTime(),
            rawGravity: gravity,
            qActGravity: qAct,
            qInverseActGravity: qInvAct,
            isDeviceToWorldConsistent: isDeviceToWorld
        )
        CameraLogger.info(report.formattedLog, category: .ai)
    }

    // MARK: - Thuc nghiem C: Stride & Shape cua MLMultiArray
    public static func logExperimentC(coords: MLMultiArray, conf: MLMultiArray) {
        guard CompositionTuning.isExperimentLoggingEnabled else { return }
        let coordsStrides = (0..<coords.strides.count).map { coords.strides[$0].intValue }
        let coordsShape = (0..<coords.shape.count).map { coords.shape[$0].intValue }
        let confStrides = (0..<conf.strides.count).map { conf.strides[$0].intValue }
        let confShape = (0..<conf.shape.count).map { conf.shape[$0].intValue }

        let log = """
        [THUC NGHIEM C] MLMultiArray ANE Output Tensor Specs
        Coordinates Tensor:
          Shape:   \(coordsShape)
          Strides: \(coordsStrides)
          Type:    \(coords.dataType == .float16 ? "Float16" : (coords.dataType == .float32 ? "Float32" : "Khac"))
          Is Contiguous: \(coordsStrides == [coordsShape[1] * coordsShape[2], coordsShape[2], 1])
        Confidence Tensor:
          Shape:   \(confShape)
          Strides: \(confStrides)
          Type:    \(conf.dataType == .float16 ? "Float16" : (conf.dataType == .float32 ? "Float32" : "Khac"))
          Is Contiguous: \(confStrides == [confShape[1] * confShape[2], confShape[2], 1])
        ------------------------------------------------------------
        """
        CameraLogger.info(log, category: .ai)
    }

    // MARK: - Thuc nghiem D: Kiem tra Tien xu ly anh
    public static func logExperimentD(
        bufferWidth: Int,
        bufferHeight: Int,
        modelInputWidth: Int,
        modelInputHeight: Int,
        cropAndScaleOption: String
    ) {
        guard CompositionTuning.isExperimentLoggingEnabled else { return }
        let log = """
        [THUC NGHIEM D] Image Preprocessing & Input Scale Verification
        Buffer nguon:      \(bufferWidth) x \(bufferHeight) (Aspect: \(String(format: "%.4f", Double(bufferWidth) / Double(bufferHeight))))
        Model Input Size:  \(modelInputWidth) x \(modelInputHeight)
        Option dang dung:  \(cropAndScaleOption)
        ------------------------------------------------------------
        """
        CameraLogger.info(log, category: .ai)
    }
}
