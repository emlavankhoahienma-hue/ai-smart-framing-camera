import Foundation
import ARKit
import SceneKit
import Combine

public final class ARCompositionSession: NSObject, ARSessionDelegate, ObservableObject {
    public static let shared = ARCompositionSession()
    
    public let arSession = ARSession()
    
    @Published public var isARSupported: Bool = false
    @Published public var arTrackingState: String = "Initializing..."
    @Published public var detectedFaceMeshCount: Int = 0
    @Published public var spatialCenterOfMass: SIMD3<Float>? = nil
    
    public override init() {
        super.init()
        checkSupport()
        arSession.delegate = self
    }
    
    private func checkSupport() {
        isARSupported = ARWorldTrackingConfiguration.isSupported
    }
    
    public func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
        if ARFaceTrackingConfiguration.isSupported {
            // Support user face mesh tracking if applicable
            config.userFaceTrackingEnabled = true
        }
        
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    
    public func pauseSession() {
        arSession.pause()
    }
    
    // MARK: - ARSessionDelegate
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Spatial anchor and plane tracking analysis
    }
    
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let faceAnchor = anchor as? ARFaceAnchor {
                processFaceGeometry(faceAnchor.geometry)
            }
        }
    }
    
    // MARK: - Process Face Geometry adhering strictly to Rule 1 (Swift Native Collection API)
    public func processFaceGeometry(_ geometry: ARFaceGeometry) {
        // RULE 1: Directly access native Swift arrays: geometry.vertices, geometry.textureCoordinates, geometry.triangleIndices
        // DO NOT use UnsafeBufferPointer and DO NOT call geometry.vertexCount (use .vertices.count)
        let vertices: [SIMD3<Float>] = geometry.vertices
        let textureCoordinates: [SIMD2<Float>] = geometry.textureCoordinates
        let triangleIndices: [Int16] = geometry.triangleIndices
        
        let count = vertices.count // Safe: using .vertices.count
        self.detectedFaceMeshCount = count
        
        guard count > 0 else { return }
        
        // Calculate 3D center of mass of the facial mesh
        var sum = SIMD3<Float>(0, 0, 0)
        for vertex in vertices {
            sum += vertex
        }
        let centerOfMass = sum / Float(count)
        
        DispatchQueue.main.async {
            self.spatialCenterOfMass = centerOfMass
        }
        
        // Example check texture coordinates and indices count safely
        _ = textureCoordinates.count
        _ = triangleIndices.count
    }
}
