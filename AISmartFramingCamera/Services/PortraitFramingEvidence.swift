import Foundation
import CoreGraphics
import Vision

/// Anatomical skeletal joints profile mapped to UI normalized coordinates (0...1, Top-Left origin).
public struct AnatomicalPoseProfile: Sendable {
    public let nose: CGPoint?
    public let leftEye: CGPoint?
    public let rightEye: CGPoint?
    public let neck: CGPoint?
    public let headTopEstimate: CGPoint?
    public let leftShoulder: CGPoint?
    public let rightShoulder: CGPoint?
    public let leftElbow: CGPoint?
    public let rightElbow: CGPoint?
    public let leftWrist: CGPoint?
    public let rightWrist: CGPoint?
    public let root: CGPoint?
    public let leftHip: CGPoint?
    public let rightHip: CGPoint?
    public let leftKnee: CGPoint?
    public let rightKnee: CGPoint?
    public let leftAnkle: CGPoint?
    public let rightAnkle: CGPoint?
    public let faceRect: CGRect?
    public let bodyRect: CGRect

    public init(
        nose: CGPoint? = nil,
        leftEye: CGPoint? = nil,
        rightEye: CGPoint? = nil,
        neck: CGPoint? = nil,
        headTopEstimate: CGPoint? = nil,
        leftShoulder: CGPoint? = nil,
        rightShoulder: CGPoint? = nil,
        leftElbow: CGPoint? = nil,
        rightElbow: CGPoint? = nil,
        leftWrist: CGPoint? = nil,
        rightWrist: CGPoint? = nil,
        root: CGPoint? = nil,
        leftHip: CGPoint? = nil,
        rightHip: CGPoint? = nil,
        leftKnee: CGPoint? = nil,
        rightKnee: CGPoint? = nil,
        leftAnkle: CGPoint? = nil,
        rightAnkle: CGPoint? = nil,
        faceRect: CGRect? = nil,
        bodyRect: CGRect
    ) {
        self.nose = nose
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.neck = neck
        self.headTopEstimate = headTopEstimate
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
        self.leftElbow = leftElbow
        self.rightElbow = rightElbow
        self.leftWrist = leftWrist
        self.rightWrist = rightWrist
        self.root = root
        self.leftHip = leftHip
        self.rightHip = rightHip
        self.leftKnee = leftKnee
        self.rightKnee = rightKnee
        self.leftAnkle = leftAnkle
        self.rightAnkle = rightAnkle
        self.faceRect = faceRect
        self.bodyRect = bodyRect
    }
}

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

    /// Extract complete 19 anatomical skeletal joints from VNHumanBodyPoseObservation in UI normalized coordinates.
    static func extractProfile(body: CGRect, faces: [CGRect], observations: [VNHumanBodyPoseObservation]) -> AnatomicalPoseProfile? {
        guard body.width > 0, body.height > 0 else { return nil }
        let face = faces.filter { body.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .max(by: { $0.width * $0.height < $1.width * $1.height })

        for observation in observations {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let p = points[name], p.confidence >= 0.35 else { return nil }
                let pt = CGPoint(x: p.location.x, y: 1 - p.location.y)
                guard pt.x.isFinite, pt.y.isFinite else { return nil }
                return pt
            }
            let nose = joint(.nose)
            let leftEye = joint(.leftEye)
            let rightEye = joint(.rightEye)
            let neck = joint(.neck)
            let leftShoulder = joint(.leftShoulder)
            let rightShoulder = joint(.rightShoulder)
            let leftElbow = joint(.leftElbow)
            let rightElbow = joint(.rightElbow)
            let leftWrist = joint(.leftWrist)
            let rightWrist = joint(.rightWrist)
            let root = joint(.root)
            let leftHip = joint(.leftHip)
            let rightHip = joint(.rightHip)
            let leftKnee = joint(.leftKnee)
            let rightKnee = joint(.rightKnee)
            let leftAnkle = joint(.leftAnkle)
            let rightAnkle = joint(.rightAnkle)

            let majorJoints = [neck, leftShoulder, rightShoulder, leftHip, rightHip].compactMap { $0 }
            guard !majorJoints.isEmpty, majorJoints.contains(where: { body.insetBy(dx: -0.1, dy: -0.1).contains($0) }) else {
                continue
            }

            var headTop: CGPoint?
            if let f = face {
                headTop = CGPoint(x: f.midX, y: f.minY)
            } else if let eye = leftEye ?? rightEye ?? nose {
                let estimatedHeadH = body.height * 0.18
                headTop = CGPoint(x: eye.x, y: max(0, eye.y - estimatedHeadH * 0.55))
            } else {
                headTop = CGPoint(x: body.midX, y: body.minY)
            }

            return AnatomicalPoseProfile(
                nose: nose, leftEye: leftEye, rightEye: rightEye, neck: neck,
                headTopEstimate: headTop, leftShoulder: leftShoulder, rightShoulder: rightShoulder,
                leftElbow: leftElbow, rightElbow: rightElbow, leftWrist: leftWrist, rightWrist: rightWrist,
                root: root, leftHip: leftHip, rightHip: rightHip,
                leftKnee: leftKnee, rightKnee: rightKnee, leftAnkle: leftAnkle, rightAnkle: rightAnkle,
                faceRect: face, bodyRect: body
            )
        }

        let fallbackHeadTop = face.map { CGPoint(x: $0.midX, y: $0.minY) } ?? CGPoint(x: body.midX, y: body.minY)
        return AnatomicalPoseProfile(
            nose: nil, leftEye: nil, rightEye: nil, neck: nil,
            headTopEstimate: fallbackHeadTop, leftShoulder: nil, rightShoulder: nil,
            leftElbow: nil, rightElbow: nil, leftWrist: nil, rightWrist: nil,
            root: nil, leftHip: nil, rightHip: nil,
            leftKnee: nil, rightKnee: nil, leftAnkle: nil, rightAnkle: nil,
            faceRect: face, bodyRect: body
        )
    }

    /// Evaluates anatomical crop safety based on Headroom Barrier and No-Joint-Cut rules.
    static func anatomicalPenalty(
        cropRect: CGRect,
        subjectBounds: CGRect,
        profile: AnatomicalPoseProfile?,
        intent: LocalCompositionIntent
    ) -> (penalty: Double, safeCropBounds: CGRect) {
        guard cropRect.width > 0, cropRect.height > 0 else { return (10.0, cropRect) }
        var penalty = 0.0
        var safeBounds = cropRect

        // Quy tac 1 - Bao ve Dinh dau (Headroom Barrier)
        let headTopY = profile?.headTopEstimate?.y ?? subjectBounds.minY
        let headroomRatio = (headTopY - cropRect.minY) / cropRect.height

        if headroomRatio < 0.04 {
            // Cat vao dau hoac sat mep tren khung hinh
            penalty += 2.5
            let neededY = max(0, headTopY - cropRect.height * 0.08)
            safeBounds.origin.y = neededY
        } else if headroomRatio > 0.22 {
            // Dau bi tut qua thap
            penalty += Double((headroomRatio - 0.22) * 2.0)
        } else if (0.06...0.15).contains(headroomRatio) {
            // Khoang tho ly tuong
            penalty -= 0.25
        }

        // Quy tac 2 - Cam cat ngang Khop xuong (No-Joint-Cut Rule)
        guard let p = profile else { return (max(0, penalty), safeBounds) }
        let dangerRadius = 0.032 * cropRect.height
        let bottomEdge = cropRect.maxY

        var criticalJoints: [CGPoint] = [
            p.leftElbow, p.rightElbow,
            p.leftWrist, p.rightWrist,
            p.leftKnee, p.rightKnee,
            p.leftAnkle, p.rightAnkle
        ].compactMap { $0 }

        if let neck = p.neck {
            criticalJoints.append(neck)
        } else if let face = p.faceRect {
            criticalJoints.append(CGPoint(x: face.midX, y: face.maxY))
        }

        for pt in criticalJoints {
            if abs(bottomEdge - pt.y) < dangerRadius {
                penalty += 0.85
            }
        }

        // Kiem tra Safe Cut Zones
        let shoulderY: CGFloat? = {
            if let l = p.leftShoulder, let r = p.rightShoulder { return (l.y + r.y) * 0.5 }
            return p.leftShoulder?.y ?? p.rightShoulder?.y
        }()
        let hipY: CGFloat? = {
            if let l = p.leftHip, let r = p.rightHip { return (l.y + r.y) * 0.5 }
            return p.leftHip?.y ?? p.rightHip?.y ?? p.root?.y
        }()
        let kneeY: CGFloat? = {
            if let l = p.leftKnee, let r = p.rightKnee { return (l.y + r.y) * 0.5 }
            return p.leftKnee?.y ?? p.rightKnee?.y
        }()
        let ankleY: CGFloat? = {
            if let l = p.leftAnkle, let r = p.rightAnkle { return (l.y + r.y) * 0.5 }
            return p.leftAnkle?.y ?? p.rightAnkle?.y
        }()

        var isSafeZone = false
        if let sY = shoulderY, let hY = hipY, hY > sY {
            let torsoHeight = hY - sY
            let cutFraction = (bottomEdge - sY) / torsoHeight
            // 1. Can canh nguc (Bust Shot): 0.38 ... 0.48 khoang cach Vai-Hong
            if (0.38...0.48).contains(cutFraction) {
                isSafeZone = true
            }
            // 2. Ban than (Medium Shot): 0.62 ... 0.75 khoang cach Vai-Hong
            if (0.62...0.75).contains(cutFraction) {
                isSafeZone = true
            }
        }
        if let hY = hipY, let kY = kneeY, kY > hY {
            let legUpperHeight = kY - hY
            let cutFraction = (bottomEdge - hY) / legUpperHeight
            // 3. Trung canh rong (Cowboy Shot): 0.45 ... 0.60 khoang cach Hong-Goi (giua dui)
            if (0.45...0.60).contains(cutFraction) {
                isSafeZone = true
            }
        }
        if let aY = ankleY {
            // 4. Toan than (Full Body Shot): bao tron mat ca chan va footroom >= 0.05 * cropRect.height
            let footroom = bottomEdge - aY
            if footroom >= 0.05 * cropRect.height {
                isSafeZone = true
            }
        }

        if isSafeZone {
            penalty = max(0, penalty - 0.35)
        }

        return (max(0, penalty), safeBounds)
    }
}
