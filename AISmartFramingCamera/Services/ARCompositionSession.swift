import Foundation
import ARKit
import SceneKit
import Combine
import UIKit

public final class ARCompositionSession: NSObject, ARSessionDelegate, ObservableObject {
    public static let shared = ARCompositionSession()
    
    public let arSession = ARSession()
    
    @Published public var isARSupported: Bool = false
    @Published public var isTrackingNormal: Bool = true
    @Published public var trackingWarningText: String? = nil
    @Published public var isTargetBehindCamera: Bool = false
    
    // Callback: (tọa độ normalized 2D trên màn hình, trạng thái tracking hợp lệ, thông báo cảnh báo)
    public var onTargetProjected: ((CGPoint, Bool, String?) -> Void)?
    
    public var viewportSize: CGSize = CGSize(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
    public var currentOrientation: UIInterfaceOrientation = .portrait
    
    public private(set) var currentAnchor: ARAnchor? = nil
    
    public override init() {
        super.init()
        checkSupport()
        arSession.delegate = self
    }
    
    private func checkSupport() {
        isARSupported = ARWorldTrackingConfiguration.isSupported
    }
    
    // MARK: - Start ARSession
    public func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            isARSupported = false
            return
        }
        isARSupported = true
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    
    public func pauseSession() {
        arSession.pause()
    }
    
    // MARK: - Pin 3D Target Anchor (Chuẩn Apple Measure App: Raycast / Feature Point / 3D Projection)
    public func pinTarget(at normalizedPoint: CGPoint, viewportSize: CGSize, orientation: UIInterfaceOrientation = .portrait) {
        self.viewportSize = viewportSize
        self.currentOrientation = orientation
        
        guard isARSupported, let currentFrame = arSession.currentFrame else { return }
        
        // Xóa anchor cũ nếu có
        if let existing = currentAnchor {
            arSession.remove(anchor: existing)
            currentAnchor = nil
        }
        
        let screenPoint = CGPoint(
            x: max(0.01, min(0.99, normalizedPoint.x)) * viewportSize.width,
            y: max(0.01, min(0.99, normalizedPoint.y)) * viewportSize.height
        )
        
        var targetTransform: simd_float4x4? = nil
        
        // 1. Raycast ra mặt phẳng ước lượng (Estimated Plane)
        let query = currentFrame.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
        let results = arSession.raycast(query)
        if let first = results.first {
            targetTransform = first.worldTransform
        }
        
        // 2. Fallback: Raycast vào existing plane
        if targetTransform == nil {
            let query2 = currentFrame.raycastQuery(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any)
            let results2 = arSession.raycast(query2)
            if let first = results2.first {
                targetTransform = first.worldTransform
            }
        }
        
        // 3. Fallback: Hit-test vào Feature Points (vùng chữ, mép cạnh, đồ vật không phải mặt phẳng)
        if targetTransform == nil {
            let hitResults = currentFrame.hitTest(screenPoint, types: [.featurePoint, .estimatedHorizontalPlane, .estimatedVerticalPlane])
            if let firstHit = hitResults.first {
                targetTransform = firstHit.worldTransform
            }
        }
        
        // 4. Fallback 3D World Anchor: Chiếu tia 3D theo góc camera 1.0m phía trước
        if targetTransform == nil {
            let cameraTransform = currentFrame.camera.transform
            var localTranslation = matrix_identity_float4x4
            localTranslation.columns.3.z = -1.0 // 1m về phía trước camera
            
            // Tính độ lệch theo góc nhìn camera
            let fovX: Float = 0.65
            let fovY: Float = fovX * Float(viewportSize.height / viewportSize.width)
            localTranslation.columns.3.x = Float(normalizedPoint.x - 0.5) * fovX
            localTranslation.columns.3.y = -Float(normalizedPoint.y - 0.5) * fovY
            
            targetTransform = matrix_multiply(cameraTransform, localTranslation)
        }
        
        if let transform = targetTransform {
            let anchor = ARAnchor(name: "AlignAI_World_Target_Anchor", transform: transform)
            arSession.add(anchor: anchor)
            self.currentAnchor = anchor
        }
    }
    
    public func clearTarget() {
        if let anchor = currentAnchor {
            arSession.remove(anchor: anchor)
            currentAnchor = nil
        }
        self.trackingWarningText = nil
        self.isTargetBehindCamera = false
    }
    
    // MARK: - ARSessionDelegate (Cập nhật 60 FPS từ Camera Pose & Anchor 3D)
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 1. Kiểm tra trạng thái tracking của camera
        let state = frame.camera.trackingState
        var isNormal = false
        var warningMessage: String? = nil
        
        switch state {
        case .normal:
            isNormal = true
            warningMessage = nil
        case .notAvailable:
            isNormal = false
            warningMessage = "AR đang khởi động..."
        case .limited(let reason):
            isNormal = false
            switch reason {
            case .excessiveMotion:
                warningMessage = "Di chuyển máy chậm lại"
            case .insufficientFeatures:
                warningMessage = "Khu vực thiếu ánh sáng/chi tiết"
            case .initializing:
                warningMessage = "Đang khởi tạo AR..."
            case .relocalizing:
                warningMessage = "Đang định vị lại..."
            @unknown default:
                warningMessage = "Đang căn chỉnh không gian..."
            }
        }
        
        DispatchQueue.main.async {
            self.isTrackingNormal = isNormal
            self.trackingWarningText = warningMessage
        }
        
        // 2. Tính toán tọa độ 2D trên màn hình từ ARAnchor 3D cố định
        guard let anchor = currentAnchor else { return }
        
        let worldPos = anchor.transform.columns.3
        let pos3D = simd_float3(worldPos.x, worldPos.y, worldPos.z)
        
        // Kiểm tra vật thể có nằm phía trước camera không (tránh chiếu ngược vật thể sau lưng)
        let camPos = simd_float3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        let toAnchor = pos3D - camPos
        let camForward = -simd_float3(frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y, frame.camera.transform.columns.2.z)
        let dotProduct = simd_dot(simd_normalize(toAnchor), camForward)
        let isBehind = dotProduct < 0.05
        
        let projected2D = frame.camera.projectPoint(
            pos3D,
            orientation: self.currentOrientation,
            viewportSize: self.viewportSize
        )
        
        let normX = projected2D.x / self.viewportSize.width
        let normY = projected2D.y / self.viewportSize.height
        
        let targetPoint = CGPoint(x: normX, y: normY)
        
        DispatchQueue.main.async {
            self.isTargetBehindCamera = isBehind
            self.onTargetProjected?(targetPoint, isNormal && !isBehind, warningMessage)
        }
    }
}
