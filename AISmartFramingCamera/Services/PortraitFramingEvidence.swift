import Foundation
import CoreGraphics
import Vision

/// Optional torso framing from measured shoulders/hips. Identity, detection
/// ranking and the tracker's complete body rectangle are never replaced.
enum PortraitFramingEvidence {
    static func bounds(body: CGRect, faces: [CGRect], observations: [VNHumanBodyPoseObservation]) -> CGRect? {
        guard let face = faces.filter({ body.contains(CGPoint(x: $0.midX, y: $0.midY)) })
            .max(by: { $0.width * $0.height < $1.width * $1.height }),
              face.width > 0.025, face.height > 0.025 else { return nil }
        for observation in observations {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
            for (name, value) in points where value.confidence >= 0.4 {
                let p = CGPoint(x: value.location.x, y: 1 - value.location.y)
                if p.x.isFinite, p.y.isFinite { joints[name] = p }
            }
            if let measured = measuredBounds(body: body, face: face, joints: joints) { return measured }
        }
        return nil
    }

    static func measuredBounds(body: CGRect, face: CGRect,
        joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGRect? {
        guard body.width > 0, body.height > 0, face.width > 0, face.height > 0,
              [body.minX, body.minY, body.maxX, body.maxY, face.minX, face.minY, face.maxX, face.maxY].allSatisfy(\.isFinite),
              joints.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let left = joints[.leftShoulder], let right = joints[.rightShoulder],
              let leftHip = joints[.leftHip], let rightHip = joints[.rightHip],
              let neck = joints[.neck] else { return nil }
        let shoulderY = (left.y + right.y) * 0.5
        let hipY = (leftHip.y + rightHip.y) * 0.5
        guard body.contains(left), body.contains(right), body.contains(leftHip), body.contains(rightHip),
              abs(neck.x - face.midX) < max(face.width, body.width * 0.2),
              neck.y >= face.midY, neck.y < face.maxY + face.height,
              hipY - shoulderY > body.height * 0.2, shoulderY > face.midY else { return nil }
        let critical = [joints[.leftElbow], joints[.rightElbow], joints[.leftWrist], joints[.rightWrist]].compactMap { $0 }
        let distance = max(0.018, face.height * 0.16)
        for fraction in [0.62, 0.72, 0.52] {
            let cut = shoulderY + (hipY - shoulderY) * CGFloat(fraction)
            guard cut > face.maxY + face.height * 0.7, cut < body.maxY - body.height * 0.12,
                  critical.allSatisfy({ abs($0.y - cut) > distance }) else { continue }
            let roi = CGRect(x: body.minX, y: body.minY, width: body.width, height: cut - body.minY)
            guard roi.contains(face), roi.contains(left), roi.contains(right) else { continue }
            return roi
        }
        return nil
    }
}
