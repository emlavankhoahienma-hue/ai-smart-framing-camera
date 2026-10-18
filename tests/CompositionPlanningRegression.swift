import Foundation
import CoreGraphics
import CoreImage
import Vision
import simd

/// Runs the production planner, projection, renderer and cancellation implementation
/// on a macOS runner. No copied numerical reference or source-string assertions.
@main
enum CompositionPlanningRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run(_ name: String, _ body: () throws -> Void) throws {
        try body()
        passed += 1
        print("PASS: \(name)")
    }

    static func raster(distractorX: Double? = nil, measured: Bool = true) -> CompositionRaster {
        let side = 24
        var luma: [Double] = [], attention: [Double] = [], edges: [Double] = []
        for y in 0..<side {
            for x in 0..<side {
                let px = (Double(x) + 0.5) / Double(side)
                let py = (Double(y) + 0.5) / Double(side)
                let subject = abs(px - 0.5) < 0.11 && abs(py - 0.5) < 0.22
                let distractor = distractorX.map { abs(px - $0) < 0.08 } ?? false
                luma.append(subject ? 0.7 : (distractor ? 0.9 : 0.25))
                attention.append(subject ? 0.8 : (distractor ? 1 : 0.05))
                edges.append(subject || distractor ? 0.7 : 0.05)
            }
        }
        return CompositionRaster(side: side, luminance: luma, attention: attention,
                                 edges: edges, hasAttention: measured)
    }

    static func subject(index: Int = 0, rect: CGRect = CGRect(x: 0.4, y: 0.28, width: 0.2, height: 0.44),
                        kind: CompositionSubjectKind = .person, gaze: CGFloat = 0,
                        confidence: Double = 0.9) -> CompositionSubject {
        CompositionSubject(index: index, bounds: rect, anchor: CGPoint(x: rect.midX, y: rect.midY),
            kind: kind, confidence: confidence, importance: 1, gaze: gaze)
    }

    static func proposals(_ subjects: [CompositionSubject], _ intents: [LocalCompositionIntent],
                          _ pixels: CompositionRaster = raster(), protected: [CGRect] = []) -> [CompositionProposal] {
        CompositionPlanner.proposals(subjects: subjects, intents: intents, raster: pixels,
            calibration: .fallback(), currentZoom: 1, allowedZooms: [0.5, 1, 2, 3],
            protectedBounds: protected)
    }

    static func main() throws {
        try run("subject-size heuristics need learned support for a deep crop") {
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: 3,
                preference: 0, originalPreference: 0.292, composition: 3.071,
                originalComposition: 3, aesthetics: 2.282, originalAesthetics: 3),
                "a low-detail zoom ignored source preference and a large aesthetic loss")
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: 3,
                preference: -2, originalPreference: 2.608, composition: 2.585,
                originalComposition: 3, aesthetics: 2.885, originalAesthetics: 3),
                "a larger subject was mistaken for a learned quality improvement")
        }
        try run("real-photo quality regressions cannot force background or false-face zooms") {
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: 2.145,
                preference: -5.5958, originalPreference: 2.1433, composition: 2.3611,
                originalComposition: 1.7372, aesthetics: 1.7750, originalAesthetics: 2.1594),
                "geometric size fit overruled the measured blurry-background crop regression")
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: 3,
                preference: -2.3188, originalPreference: 2.4562, composition: 1.7143,
                originalComposition: 1.6974, aesthetics: 2.1875, originalAesthetics: 2.5766),
                "a false-face crop ignored the learned quality audit")
        }
        try run("an optical-profile search cannot trade a large aesthetic loss for a small composition gain") {
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: 3.1380835797261506,
                preference: -0.6821336150169373, originalPreference: -0.35570865869522095,
                composition: 2.9018092193115654, originalComposition: 2.7617415597401704,
                aesthetics: 1.825114111906705, originalAesthetics: 2.594860818610726),
                "a slight composition increase hid the observed optical-profile quality regression")
        }
        try run("quality audits retain a measured beneficial crop and reject invalid evidence") {
            try require(LearnedFramingPolicy.passesQualityAudit(zoomRatio: 2,
                preference: -3.0418, originalPreference: 2.2622, composition: 1.7015,
                originalComposition: 1.9674, aesthetics: 3.0014, originalAesthetics: 2.8553),
                "an actual aesthetic improvement was vetoed only for changing the frame")
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: .nan,
                preference: 1, originalPreference: 0, composition: 3,
                originalComposition: 3, aesthetics: 3, originalAesthetics: 3), "invalid quality evidence was accepted")
        }
        try run("large context-losing zoom needs modern aesthetic support") {
            try require(!LearnedFramingPolicy.passesQualityAudit(zoomRatio: 3,
                preference: -3.3092877864837646, originalPreference: 2.1484475135803223,
                composition: 2.806558915417685, originalComposition: 2.641033515676749,
                aesthetics: 2.813345696819836, originalAesthetics: 2.83544228938578),
                "A small SAMP gain authorized the observed bedroom context loss")
            try require(LearnedFramingPolicy.passesQualityAudit(zoomRatio: 2.0006388446097896,
                preference: -2.1245810985565186, originalPreference: 0.8615694046020508,
                composition: 2.652257257873008, originalComposition: 2.8534961577956857,
                aesthetics: 3.0910041043011245, originalAesthetics: 2.8559328016484775),
                "The measured two-worker crop lost a real modern-aesthetic gain")
        }
        try run("identity camera corners tolerate mixed boundary roundoff") {
            let noise: CGFloat = 0.0000000000000001
            let corners = [CGPoint(x: -noise, y: -noise), CGPoint(x: 1, y: -noise),
                           CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            try require(CompositionViewSupport.fraction(corners) > 0.999999, "a complete source frame became unobserved")
            try require(CompositionViewSupport.region(corners) == CGRect(x: 0, y: 0, width: 1, height: 1),
                "one-ULP identity noise invalidated the original crop")
            try require(CompositionViewSupport.containsEntireView(corners), "identity roundoff required a new scene")
        }
        try run("a face landmark outside the body cannot erase every framing proposal") {
            let body = CGRect(x: 0.0003662109375, y: 0.1546238687782805,
                              width: 0.357421875, height: 0.8349830316742081)
            let face = CGRect(x: 0.31617119908332825, y: 0.23021098226308823,
                              width: 0.08385621756315231, height: 0.12128356844186783)
            let preferred = CGPoint(x: face.midX, y: face.midY)
            try require(!body.contains(preferred), "fixture no longer crosses the body boundary")
            let anchor = CompositionSubject.framingAnchor(bounds: body, preferred: preferred)
            let measured = subject(rect: body, kind: .person)
            let framed = CompositionSubject(index: measured.index, bounds: body, anchor: anchor,
                kind: measured.kind, confidence: measured.confidence, importance: measured.importance, gaze: measured.gaze)
            let plans = CompositionPlanner.photographicProposals(subject: framed, intents: [.portrait, .environmentalPortrait],
                portraitBounds: nil, raster: raster(), calibration: .fallback(), currentZoom: 1,
                allowedZooms: [1, 2, 3], protectedBounds: [face], proposalLimit: 72, allowsCameraPan: true)
            try require(plans.contains(where: \.isUnchangedView), "inconsistent eye/body evidence erased the valid source view")
            let validEye = CGPoint(x: body.midX, y: body.minY + 0.05)
            try require(CompositionSubject.framingAnchor(bounds: body, preferred: validEye) == validEye,
                "a valid measured eye was replaced")
        }
        try run("a thin revealed triangle cannot use full-source preview rendering") {
            // Actual failing footprint from the occluded three-person photo 1565.
            let corners = [CGPoint(x: -0.0006566634113889247, y: 0.23697605745611228),
                CGPoint(x: 0.40799289180244735, y: 0.2605805690377059),
                CGPoint(x: 0.4133380715944237, y: 0.6118408560032975),
                CGPoint(x: 0.015220758988522542, y: 0.6485732638944031)]
            try require(CompositionViewSupport.fraction(corners) > 0.9999, "fixture no longer exercises near-unit support")
            try require(!CompositionViewSupport.containsEntireView(corners), "area support hid an unobserved corner")
            let renderer = CompositionImageRenderer()
            let source = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.2))
                .cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 768))
            try require(renderer.observedPreview(image: source, corners: corners, aspect: 4.0 / 3) != nil,
                "a thin outside triangle still fails the production preview")
        }
        try run("verified telephoto optics extend search while digital presets stay bounded") {
            let item = subject(rect: CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.12), kind: .object)
            func plans(_ optical: CGFloat?) -> [CompositionProposal] {
                CompositionPlanner.photographicProposals(subject: item, intents: [.object], portraitBounds: nil,
                    raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3, 5],
                    proposalLimit: 72, allowsCameraPan: true, maximumOpticalZoom: optical)
            }
            try require(plans(nil).allSatisfy { $0.zoom <= 3.0001 }, "a digital preset was mistaken for an optical lens")
            try require(plans(5).contains { $0.zoom >= 4.5 }, "available telephoto was excluded from safe framing")
            try require(plans(9).allSatisfy { $0.zoom <= 3.0001 }, "an unadvertised lens exceeded hardware bounds")
        }
        try run("large attention regions can crop background while physical object outlines stay protected") {
            var region = subject(rect: CGRect(x: 0.01, y: 0.01, width: 0.98, height: 0.98), kind: .object)
            region.allowsAttentionCrop = true
            let plans = CompositionPlanner.photographicProposals(subject: region, intents: [.object], portraitBounds: nil,
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3])
            try require(plans.contains { $0.zoom > 1.2 }, "a field of saliency was treated as one uncuttable object")
            try require(plans.allSatisfy { $0.isUnchangedView || $0.retainedAttention >= 0.82 }, "lost the measured focus of attention")
            region.allowsAttentionCrop = false
            let solid = CompositionPlanner.photographicProposals(subject: region, intents: [.object], portraitBounds: nil,
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3])
            try require(!solid.contains { $0.zoom > 1.1 }, "a physical object was cut as background")
            region.allowsAttentionCrop = true
            let pixels = raster()
            let uniform = CompositionRaster(side: pixels.side, luminance: pixels.luminance,
                attention: Array(repeating: 0.5, count: pixels.attention.count), edges: pixels.edges, hasAttention: true)
            let diffuse = CompositionPlanner.photographicProposals(subject: region, intents: [.object], portraitBounds: nil,
                raster: uniform, calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3])
            try require(!diffuse.isEmpty && !diffuse.contains { $0.zoom > 1.15 }, "diffuse attention authorized an aggressive crop")
            let absent = CompositionPlanner.photographicProposals(subject: region, intents: [.object], portraitBounds: nil,
                raster: raster(measured: false), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3])
            try require(!absent.contains { $0.zoom > 1.1 }, "missing saliency fabricated attention retention")
        }
        try run("manual review age starts after real cold inference without permitting stale previews") {
            try require(CompositionAnalysisReceipt.acceptsSelection(sourceTimestamp: 10, completedAt: 65, now: 70),
                "cold model result expired before review")
            try require(!CompositionAnalysisReceipt.acceptsSelection(sourceTimestamp: 10, completedAt: 65, now: 81),
                "old open preview remained actionable")
            try require(!CompositionAnalysisReceipt.acceptsSelection(sourceTimestamp: 10, completedAt: 100, now: 101),
                "unbounded source age accepted")
            try require(!CompositionAnalysisReceipt.acceptsSelection(sourceTimestamp: 80, completedAt: 65, now: 70),
                "future source image accepted")
        }
        try run("crop preference is relative to one image and rejects invalid values") {
            let scores = [-2.0, 0, 2]
            try require(LearnedFramingPolicy.preferencePercentile(2, among: scores) ==
                LearnedFramingPolicy.preferencePercentile(12, among: scores.map { $0 + 10 }), "logit offset changed the selected crop")
            try require(LearnedFramingPolicy.preferencePercentile(.nan, among: scores) == nil, "invalid rank accepted")
            try require(LearnedFramingPolicy.preferencePercentile(1, among: []) == nil, "empty ranks became evidence")
        }
        try run("composition alignment follows the chosen aim while the tracker stays on the subject") {
            let k = TrackingCalibration.fallback()
            let identity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
            let subject = CGPoint(x: 0.30, y: 0.40)
            let bearing = k.deviceRay(at: subject)
            let aim = k.deviceRay(at: CGPoint(x: 0.60, y: 0.55))
            guard let guide = CompositionAimGeometry(subject: subject, calibration: k, sourcePose: identity, aimWorldRay: aim) else {
                throw Failure(description: "valid composition guide rejected")
            }
            let aimPose = simd_quatd(from: SIMD3(0, 0, -1), to: aim)
            let physical = k.project(deviceRay: aimPose.inverse.act(bearing))
            let projected = guide.projection(subject: physical.point, calibration: k, pose: aimPose)!
            try require(hypot(projected.point.x - 0.5, projected.point.y - 0.5) < 0.000001, "camera aim did not align")
            try require(hypot(physical.point.x - 0.5, physical.point.y - 0.5) > 0.1, "test accidentally centered the tracked subject")
            let subjectPose = simd_quatd(from: SIMD3(0, 0, -1), to: bearing)
            let wrong = guide.projection(subject: CGPoint(x: 0.5, y: 0.5), calibration: k, pose: subjectPose)!
            try require(hypot(wrong.point.x - 0.5, wrong.point.y - 0.5) > 0.1, "centering a subject falsely confirmed an off-center composition")
            let zoomed = TrackingCalibration.fallback(zoom: 2)
            let rolled = aimPose * simd_quatd(angle: 0.4, axis: SIMD3(0, 0, -1))
            let tracked = zoomed.project(deviceRay: rolled.inverse.act(bearing))
            let correct = guide.projection(subject: tracked.point, calibration: zoomed, pose: rolled)!
            try require(hypot(correct.point.x - 0.5, correct.point.y - 0.5) < 0.000001, "roll or lens zoom changed the planned aim")
        }
        try run("invalid composition rays cannot authorize alignment") {
            let k = TrackingCalibration.fallback()
            let pose = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
            try require(CompositionAimGeometry(subject: CGPoint(x: .nan, y: 0.5), calibration: k,
                sourcePose: pose, aimWorldRay: SIMD3(0, 0, -1)) == nil, "nonfinite subject accepted")
            try require(CompositionAimGeometry(subject: CGPoint(x: 0.5, y: 0.5), calibration: k,
                sourcePose: pose, aimWorldRay: .zero) == nil, "zero aim accepted")
        }
        try run("portrait crop protection is independent of full-body tracking bounds") {
            let body = CGRect(x: 0.3, y: 0.08, width: 0.4, height: 0.86)
            let torso = CGRect(x: 0.3, y: 0.08, width: 0.4, height: 0.45)
            let eye = CGPoint(x: 0.5, y: 0.2)
            try require(CompositionCropProtection.bounds(body: body, portrait: torso, intent: .portrait, anchor: eye) == torso,
                "intentional torso crop still protects all legs")
            for intent in [LocalCompositionIntent.group, .environmentalPortrait, .landscape] {
                try require(CompositionCropProtection.bounds(body: body, portrait: torso, intent: intent, anchor: eye) == body,
                    "non-portrait lost full subject protection")
            }
            try require(CompositionCropProtection.bounds(body: body, portrait: nil, intent: .portrait, anchor: eye) == body,
                "missing measurements invented a crop")
        }
        try run("a subject anchor at the image edge still has an unchanged safe view") {
            let hero = CompositionSubject(index: 0, bounds: CGRect(x: 0, y: 0.18, width: 0.18, height: 0.65),
                anchor: CGPoint(x: 0.02, y: 0.25), kind: .person, confidence: 0.9, importance: 1, gaze: 0)
            let result = CompositionPlanner.photographicProposals(subject: hero, intents: [.portrait], portraitBounds: nil,
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3])
            try require(result.contains(where: \.isUnchangedView), "edge anchor excluded the only safe original frame")
        }
        try run("measured torso portrait enables zoom while keeping face and shoulders") {
            let body = CGRect(x: 0.35, y: 0.10, width: 0.30, height: 0.84)
            let face = CGRect(x: 0.43, y: 0.11, width: 0.14, height: 0.14)
            let joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [
                .leftShoulder: CGPoint(x: 0.39, y: 0.31), .rightShoulder: CGPoint(x: 0.61, y: 0.31),
                .leftHip: CGPoint(x: 0.43, y: 0.66), .rightHip: CGPoint(x: 0.57, y: 0.66),
                .neck: CGPoint(x: 0.50, y: 0.29)]
            guard let roi = PortraitFramingEvidence.measuredBounds(body: body, face: face, joints: joints) else {
                throw Failure(description: "reliable torso evidence was discarded")
            }
            try require(roi.contains(face) && roi.contains(joints[.leftShoulder]!) && roi.contains(joints[.rightShoulder]!), "portrait cuts face or shoulders")
            let hero = CompositionSubject(index: 0, bounds: body, anchor: CGPoint(x: face.midX, y: face.midY),
                kind: .person, confidence: 0.95, importance: 1, gaze: 0)
            let plans = CompositionPlanner.photographicProposals(subject: hero, intents: [.portrait, .environmentalPortrait],
                portraitBounds: roi, raster: raster(), calibration: .fallback(), currentZoom: 1,
                allowedZooms: [1, 2, 3], protectedBounds: [face])
            try require(plans.contains { $0.intent == .portrait && $0.zoom > 1.4 }, "all useful portrait zoom was forbidden by full-body bounds")
            try require(plans.contains(where: \.isUnchangedView), "portrait search discarded original frame")
            var missing = joints
            missing.removeValue(forKey: .leftHip)
            try require(PortraitFramingEvidence.measuredBounds(body: body, face: face, joints: missing) == nil, "missing pose invented a torso crop")
            var crowdedCut = joints
            crowdedCut[.leftElbow] = CGPoint(x: 0.4, y: 0.527)
            crowdedCut[.rightElbow] = CGPoint(x: 0.6, y: 0.562)
            crowdedCut[.leftWrist] = CGPoint(x: 0.4, y: 0.492)
            try require(PortraitFramingEvidence.measuredBounds(body: body, face: face, joints: crowdedCut) == nil, "crop crosses a measured elbow or wrist")
        }
        try run("photographic intent constrains whole-image conservatism without forcing every frame to change") {
            try require(!LearnedFramingPolicy.admissible(geometry: 0.55, best: 0.72), "poor subject framing was preserved by a whole-image score")
            try require(LearnedFramingPolicy.admissible(geometry: 0.71, best: 0.72), "already suitable original framing was forced to move")
            let crop = LearnedFramingPolicy.score(preference: 2, peers: [-2, 0, 2], composition: 3, aesthetics: 3, geometry: 0.8)!
            let original = LearnedFramingPolicy.score(preference: -2, peers: [-2, 0, 2], composition: 3.5, aesthetics: 3.4, geometry: 0.8)!
            try require(crop > original, "whole-image ratings overruled strong trained crop preference")
            try require(LearnedFramingPolicy.score(preference: 1, peers: [1], composition: .nan, aesthetics: 3, geometry: 0.8) == nil,
                        "invalid audit ratings admitted")
        }
        try run("each button press requires its own captured image") {
            let request = UUID(), later = UUID()
            let receipt = CompositionAnalysisReceipt(requestID: request, sourceTimestamp: 42,
                elapsed: 1.2, assessedFrames: 48, usedSpecialist: true)
            try require(receipt.belongs(to: request, timestamp: 42), "warm inference was rejected only because it is fast")
            try require(!receipt.belongs(to: later, timestamp: 42), "a previous request authorized a new target")
            try require(!receipt.belongs(to: request, timestamp: 43), "a previous image authorized a new target")
        }
        try run("capture admission rejects queued old frames and invalid clocks") {
            try require(!CompositionAnalysisReceipt.acceptsFrame(timestamp: 9.99, requestedAt: 10, now: 10.1), "pre-press frame admitted")
            try require(!CompositionAnalysisReceipt.acceptsFrame(timestamp: 10.1, requestedAt: 10, now: 11.2), "stalled delivery admitted")
            try require(!CompositionAnalysisReceipt.acceptsFrame(timestamp: .nan, requestedAt: 10, now: 10.1), "nonfinite frame admitted")
            try require(CompositionAnalysisReceipt.acceptsFrame(timestamp: 10.03, requestedAt: 10, now: 10.05), "fresh frame rejected")
        }
        try run("unavailable crop weights cannot be replaced by fabricated quality evidence") {
            let ci = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
                .cropped(to: CGRect(x: 0, y: 0, width: 216, height: 288))
            let result = CompositionAestheticSearch(renderer: CompositionImageRenderer()).run(
                proposals: proposals([subject()], [.portrait]), image: ci, aspect: 0.75,
                preferences: [:], modelURL: nil, cancellation: CompositionAnalysisCancellation(),
                progress: { _ in }, refine: { _ in [] })
            try require(result == nil, "geometry was reported as a trained model result")
        }
        try run("learned shortlist explores zoom while retaining the unchanged view") {
            let plans = CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait, .environmentalPortrait],
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3], proposalLimit: 36)
            try require(plans.count > 6 && plans.count <= 36, "trained model received only the old small shortlist")
            try require(plans.contains(where: \.isUnchangedView), "unchanged baseline omitted")
            try require((plans.map(\.zoom).max() ?? 1) > 1.25, "focal-length exploration collapsed")
        }
        try run("learned local refinement keeps every member in a five-person group") {
            let members = (0..<5).map { CGRect(x: 0.15 + Double($0) * 0.13, y: 0.22, width: 0.11, height: 0.55) }
            let union = members.dropFirst().reduce(members[0]) { $0.union($1) }
            let hero = subject(rect: union, kind: .group)
            let broad = CompositionPlanner.proposals(subjects: [hero], intents: [.group], raster: raster(),
                calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3], protectedBounds: members, proposalLimit: 36)
            let refined = CompositionPlanner.proposals(subjects: [hero], intents: [.group], raster: raster(),
                calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3], protectedBounds: members,
                proposalLimit: 18, refining: Array(broad.prefix(3)))
            try require(!refined.isEmpty && refined.count <= 18, "missing bounded refinement")
            for plan in refined {
                let k = TrackingCalibration.fallback()
                let future = TrackingCalibration(fx: k.fx * Double(plan.zoom), fy: k.fy * Double(plan.zoom),
                    cx: k.cx, cy: k.cy, aspect: k.aspect)
                for member in members {
                    let projected = CompositionPlanner.project(member, from: k, to: future, rotation: plan.rotation)
                    try require(projected.map { CompositionPlanner.visibleFraction($0) > 0.98 } == true, "refinement cut a group member")
                }
            }
        }
        try run("missing composition weights never authorize an automatic target") {
            let renderer = CompositionImageRenderer()
            let ci = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
                .cropped(to: CGRect(x: 0, y: 0, width: 216, height: 288))
            let result = CompositionAestheticSearch(renderer: renderer).run(proposals: proposals([subject()], [.portrait]),
                image: ci, aspect: 0.75, preferences: [:], modelURL: nil,
                cancellation: CompositionAnalysisCancellation(), progress: { _ in }, refine: { _ in [] })
            try require(result == nil, "missing weights authorized an automatic target")
        }
        try run("spectral preprocessing remains finite on flat and black images") {
            let context = CIContext()
            let spectral = SpectralCompositionSaliency()
            for value in [0.0, 0.02, 1.0] {
                let ci = CIImage(color: CIColor(red: value, green: value, blue: value))
                let image = context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: 216, height: 288))!
                guard let map = spectral.map(image: image) else { throw Failure(description: "flat input failed") }
                try require(map.count == 224 * 224 && map.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.00001 },
                            "spectral saliency diverged on flat input")
            }
        }
        try run("background faces are retained whole or excluded whole") {
            let face = CGRect(x: 0.79, y: 0.25, width: 0.1, height: 0.14)
            let k = TrackingCalibration.fallback()
            let plans = CompositionPlanner.proposals(subjects: [subject(kind: .object)], intents: [.object],
                raster: raster(), calibration: k, currentZoom: 1, allowedZooms: [1, 2, 3], incidentalBounds: [face])
            try require(!plans.isEmpty, "lost current uncut image")
            for plan in plans {
                let future = TrackingCalibration(fx: k.fx * Double(plan.zoom), fy: k.fy * Double(plan.zoom),
                    cx: k.cx, cy: k.cy, aspect: k.aspect)
                guard let rect = CompositionPlanner.project(face, from: k, to: future, rotation: plan.rotation) else { continue }
                let fraction = CompositionPlanner.visibleFraction(rect)
                try require(fraction <= 0.02 || fraction >= 0.98, "bisected a background face")
            }
        }
        try run("overlapping people keep distinct face identities") {
            let a = CGRect(x: 0.20, y: 0.20, width: 0.4, height: 0.7)
            let b = CGRect(x: 0.30, y: 0.20, width: 0.4, height: 0.7)
            let eyeA = CGPoint(x: 0.35, y: 0.3), eyeB = CGPoint(x: 0.55, y: 0.3)
            try require(!HeroSubjectPolicy.duplicate(a, b, eyeA: eyeA, eyeB: eyeB), "merged two people")
            try require(HeroSubjectPolicy.duplicate(a, a, eyeA: eyeA, eyeB: eyeA), "duplicate detector box survived")
        }
        try run("face association follows head geometry instead of request order or face size") {
            let body = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.7)
            let ownFace = CGRect(x: 0.43, y: 0.25, width: 0.1, height: 0.12)
            let incidental = CGRect(x: 0.29, y: 0.44, width: 0.18, height: 0.18)
            let own = HeroSubjectPolicy.faceAffinity(face: ownFace, body: body) ?? 0
            let other = HeroSubjectPolicy.faceAffinity(face: incidental, body: body) ?? 0
            try require(own > other, "largest incidental face captured the body")
        }
        try run("hero ranking suppresses tiny background people and survives invalid input") {
            let hero = CGRect(x: 0.32, y: 0.20, width: 0.35, height: 0.65)
            let background = CGRect(x: 0.08, y: 0.32, width: 0.04, height: 0.08)
            let main = HeroSubjectPolicy.score(bounds: hero, kind: .person, confidence: 0.85, evidence: nil, hasFace: true)
            let noise = HeroSubjectPolicy.score(bounds: background, kind: .person, confidence: 0.99, evidence: nil)
            try require(main > noise * 2, "tiny confident passer-by defeated the hero")
            try require(HeroSubjectPolicy.score(bounds: hero, kind: .object, confidence: .nan, evidence: nil) == 0, "NaN rank")
        }
        try run("saliency and local separation can select an object over an incidental person") {
            let strong = SubjectVisualEvidence(attentionDensity: 0.95, attentionShare: 0.75,
                separation: 0.9, detail: 0.8, exposure: 0.9)
            let weak = SubjectVisualEvidence(attentionDensity: 0.05, attentionShare: 0.01,
                separation: 0.1, detail: 0.2, exposure: 0.9)
            let object = HeroSubjectPolicy.score(bounds: CGRect(x: 0.25, y: 0.3, width: 0.45, height: 0.4),
                kind: .object, confidence: 0.9, evidence: strong)
            let person = HeroSubjectPolicy.score(bounds: CGRect(x: 0.05, y: 0.3, width: 0.08, height: 0.18),
                kind: .person, confidence: 0.95, evidence: weak)
            try require(object > person, "semantic class overrode foreground evidence")
        }
        try run("presentation identity hysteresis needs sustained superiority") {
            var selector = HeroIdentitySelector()
            let a = UUID(), b = UUID()
            try require(selector.select([(a, 0.6), (b, 0.58)], timestamp: 1) == a, "initial identity")
            try require(selector.select([(a, 0.60), (b, 0.63)], timestamp: 1.1) == a, "rank flicker")
            try require(selector.select([(a, 0.50), (b, 0.85)], timestamp: 1.2) == a, "immediate switch")
            try require(selector.select([(a, 0.50), (b, 0.85)], timestamp: 1.8) == b, "never switches")
            try require(selector.select([], timestamp: 1.9) == nil, "stale hero on empty frame")
        }
        try run("five comparable people form a group but a distant bystander does not") {
            let people = (0..<5).map { CGRect(x: 0.05 + Double($0) * 0.18, y: 0.25, width: 0.15, height: 0.55) }
            for i in 1..<people.count { try require(HeroSubjectPolicy.coherent(people[i - 1], people[i]), "split group") }
            let distant = CGRect(x: 0.88, y: 0.4, width: 0.03, height: 0.08)
            try require(!HeroSubjectPolicy.coherent(people[4], distant), "group includes background person")
        }
        try run("blank and low-light rasters do not manufacture detailed subjects") {
            let blank = CompositionRaster(side: 8, luminance: Array(repeating: 0.01, count: 64),
                attention: Array(repeating: 0, count: 64), edges: Array(repeating: 0, count: 64), hasAttention: false)
            try require(blank.sceneryAnchor == nil && blank.horizon == nil, "blank scene invented evidence")
            guard let e = blank.evidence(in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)) else {
                throw Failure(description: "missing valid black raster measurements")
            }
            try require(e.detail == 0 && e.exposure < 0.1 && e.attentionShare == 0, "dark evidence amplified")
            try require(proposals([], [.object], blank).isEmpty, "empty frame returned a target")
        }
        try run("gaze changes the solved pan direction and leaves looking room") {
            let left = proposals([subject(gaze: -0.9)], [.portrait])
            let right = proposals([subject(gaze: 0.9)], [.portrait])
            guard let a = left.first, let b = right.first else { throw Failure(description: "missing gaze plans") }
            try require(a.expectedSubjectRect.midX > b.expectedSubjectRect.midX, "looking room reversed")
            try require(a.aimPoint.x < b.aimPoint.x, "guide bearing reversed")
        }
        try run("continuous focal-length solution respects source resolution and hardware") {
            let plans = CompositionPlanner.proposals(subjects: [subject(kind: .object)], intents: [.object],
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 1.7])
            try require(!plans.isEmpty && plans.allSatisfy { $0.zoom >= 1 && $0.zoom <= 1.7 }, "zoom exceeds lens range")
            try require(plans.contains { abs($0.zoom - 1) > 0.01 && abs($0.zoom - 1.7) > 0.01 }, "only discrete focal lengths")
            try require(CompositionPlanner.diverse(plans, limit: 0).isEmpty, "zero alternatives ignored")
        }
        try run("every offered frame uses only observed source pixels") {
            let plans = proposals([subject(gaze: 0.8)], [.portrait])
            try require(!plans.isEmpty, "no portrait plans")
            for plan in plans {
                try require(plan.sourceCorners.count == 4, "invalid footprint")
                try require(plan.sourceCorners.allSatisfy {
                    (-0.00001...1.00001).contains($0.x) && (-0.00001...1.00001).contains($0.y)
                }, "invented pixels outside source")
                try require(plan.zoom >= 1 && plan.score.isFinite, "invalid zoom or ranking")
                let calibration = TrackingCalibration.fallback()
                let future = TrackingCalibration(fx: calibration.fx * Double(plan.zoom),
                    fy: calibration.fy * Double(plan.zoom), cx: 0.5, cy: 0.5, aspect: 0.75)
                let mapped = future.project(deviceRay: plan.rotation.inverse.act(calibration.deviceRay(at: plan.subjectPoint)))
                try require(plan.expectedSubjectRect.insetBy(dx: -0.001, dy: -0.001).contains(mapped.point),
                            "tracking anchor and predicted subject disagree")
            }
        }
        try run("companions outside the selected subject remain visible") {
            let companion = CGRect(x: 0.84, y: 0.25, width: 0.12, height: 0.55)
            let plans = proposals([subject()], [.group], protected: [companion])
            try require(!plans.isEmpty, "lost safe current frame")
            for plan in plans {
                let source = TrackingCalibration.fallback()
                let future = TrackingCalibration(fx: source.fx * Double(plan.zoom),
                    fy: source.fy * Double(plan.zoom), cx: 0.5, cy: 0.5, aspect: 0.75)
                guard let mapped = CompositionPlanner.project(companion, from: source, to: future,
                                                              rotation: plan.rotation) else {
                    throw Failure(description: "companion not projectable")
                }
                try require(mapped.minX >= 0.024 && mapped.maxX <= 0.976 &&
                            mapped.minY >= 0.024 && mapped.maxY <= 0.976, "cropped companion")
            }
        }
        try run("environmental portrait retains a wider context than a tight portrait") {
            let tight = proposals([subject()], [.portrait])
            let wide = proposals([subject()], [.environmentalPortrait, .landscape])
            guard let p = tight.first, let e = wide.first else { throw Failure(description: "missing plans") }
            try require(e.intent == .environmentalPortrait, "scene intent lost")
            try require(e.zoom <= p.zoom, "environmental plan crops more than portrait")
        }
        try run("a detected group cannot inherit a single-person portrait intent") {
            let group = subject(rect: CGRect(x: 0.12, y: 0.18, width: 0.76, height: 0.67), kind: .group)
            let plans = proposals([group, subject(index: 1)], [.portrait])
                .filter { $0.subjectIndex == group.index }
            try require(!plans.isEmpty && plans.allSatisfy { $0.intent == .group }, "group treated as a portrait")
        }
        try run("scenery needs a real texture anchor and preserves the wide frame") {
            guard let anchor = raster().sceneryAnchor else { throw Failure(description: "texture anchor missing") }
            let scene = subject(rect: CGRect(x: anchor.x - 0.04, y: anchor.y - 0.04, width: 0.08, height: 0.08),
                                kind: .scenery, confidence: 0.45)
            guard let best = proposals([scene], [.landscape]).first else { throw Failure(description: "no landscape") }
            try require(best.zoom <= 1.15, "landscape cropped around tracking patch")
            try require(best.evidenceConfidence == 0.45, "invented detector confidence")
            let empty = CompositionRaster(side: 8, luminance: Array(repeating: 0.5, count: 64),
                attention: Array(repeating: 0, count: 64), edges: Array(repeating: 0, count: 64), hasAttention: false)
            try require(empty.sceneryAnchor == nil, "invented anchor on a blank sky")
        }
        try run("flower and object plans keep the entire detected outline") {
            let flower = subject(rect: CGRect(x: 0.36, y: 0.36, width: 0.28, height: 0.28), kind: .object)
            let plans = proposals([flower], [.closeUp])
            try require(!plans.isEmpty, "no close-up options")
            try require(plans.allSatisfy { $0.intent == .closeUp &&
                $0.expectedSubjectRect.minX >= 0.024 && $0.expectedSubjectRect.maxX <= 0.976 &&
                $0.expectedSubjectRect.minY >= 0.024 && $0.expectedSubjectRect.maxY <= 0.976
            }, "cut petals or wrong intent")
        }
        try run("background evidence changes layout ranking") {
            let target = subject(rect: CGRect(x: 0.43, y: 0.35, width: 0.14, height: 0.3), kind: .object)
            let left = proposals([target], [.object], raster(distractorX: 0.25))
            let right = proposals([target], [.object], raster(distractorX: 0.75))
            guard let a = left.first, let b = right.first else { throw Failure(description: "no background plans") }
            try require(abs(a.aimPoint.x - b.aimPoint.x) > 0.01 ||
                        abs(a.score - b.score) > 0.0001 ||
                        left.map(\.aimPoint) != right.map(\.aimPoint), "planner ignored background")
        }
        try run("invalid calibration and cancelled search produce no action") {
            let bad = TrackingCalibration(fx: .nan, fy: 1, cx: 0.5, cy: 0.5, aspect: 0.75)
            try require(CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait],
                raster: raster(), calibration: bad, currentZoom: 1, allowedZooms: [1, 2]).isEmpty, "accepted NaN")
            var checks = 0
            let cancelled = CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait],
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2]) {
                    checks += 1; return checks > 2
                }
            try require(cancelled.isEmpty && checks <= 3, "search continued after cancellation")
        }
        try run("existing telephoto zoom remains available above the search cap") {
            let plans = CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait],
                raster: raster(), calibration: .fallback(zoom: 6), currentZoom: 6, allowedZooms: [1, 2, 3])
            try require(!plans.isEmpty && plans.allSatisfy { $0.zoom == 6 }, "lost current 6x frame")
        }
        try run("fallback without attention keeps evidence confidence separate from score") {
            let plans = proposals([subject(confidence: 0.38)], [.portrait], raster(measured: false))
            try require(!plans.isEmpty && plans.allSatisfy { $0.evidenceConfidence == 0.38 }, "confidence inflated")
        }
        try run("preview and raster preserve top-bottom orientation") {
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 32, width: 48, height: 32))
            let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
            let image = red.composited(over: blue)
            let renderer = CompositionImageRenderer()
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            guard let preview = renderer.preview(image: image, corners: corners, aspect: 0.75),
                  let evidence = renderer.raster(image: CIImage(cgImage: preview), saliency: nil) else {
                throw Failure(description: "image rendering failed")
            }
            try require(preview.width == 216 && preview.height == 288, "preview aspect changed")
            let top = evidence.value(evidence.luminance, at: CGPoint(x: 0.5, y: 0.2))
            let bottom = evidence.value(evidence.luminance, at: CGPoint(x: 0.5, y: 0.8))
            try require(top > bottom + 0.05, "raster vertically inverted")
        }
        try run("cancelled Vision request cannot execute") {
            let context = CIContext()
            let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            guard let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 32, height: 32)) else {
                throw Failure(description: "fixture creation failed")
            }
            let cancellation = CompositionAnalysisCancellation()
            cancellation.cancel()
            do {
                try cancellation.perform(VNDetectFaceRectanglesRequest(),
                    with: VNImageRequestHandler(cgImage: cgImage, options: [:]))
                throw Failure(description: "cancelled request executed")
            } catch is CancellationError { }
        }
        try run("visible composition aim unlocks alignment while physical subject remains off center") {
            let k = TrackingCalibration.fallback()
            let physical = CGPoint(x: 0.32, y: 0.41)
            let requested = CGPoint(x: 0.57, y: 0.48)
            let ray = k.deviceRay(at: requested)
            let pose = simd_quatd(from: SIMD3(0, 0, -1), to: ray)
            guard let geometry = CompositionAimGeometry(subject: physical, calibration: k,
                sourcePose: simd_quatd(angle: 0, axis: SIMD3(0, 1, 0)), aimWorldRay: ray),
                  let guide = geometry.projection(subject: k.project(deviceRay: pose.inverse.act(k.deviceRay(at: physical))).point,
                                                  calibration: k, pose: pose) else {
                throw Failure(description: "Missing measured subject/aim projection")
            }
            let subject = k.project(deviceRay: pose.inverse.act(k.deviceRay(at: physical)))
            let distance = hypot(guide.point.x - 0.5, (guide.point.y - 0.5) / CGFloat(k.aspect))
            try require(distance < 0.00001, "Visible aim did not reach the fixed center ring")
            try require(hypot(subject.point.x - 0.5, subject.point.y - 0.5) > 0.1,
                        "Fixture silently centered the subject instead of the photographic aim")
            var gate = AlignmentCaptureGate()
            for i in 0...30 {
                _ = gate.update(time: Double(i) / 60, distance: Double(distance), radius: 0.038, freshEvidence: true)
            }
            try require(gate.isAligned, "Displayed aim and admission disagreed")
        }
        try run("composition guide reprojects the delivered world bearing across delayed frames and zoom") {
            let original = TrackingCalibration.fallback()
            let subject = CGPoint(x: 0.31, y: 0.42)
            let desired = CGPoint(x: 0.57, y: 0.46)
            let identity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
            let desiredWorld = original.deviceRay(at: desired)
            guard let geometry = CompositionAimGeometry(subject: subject, calibration: original,
                sourcePose: identity, aimWorldRay: desiredWorld) else { throw Failure(description: "Missing guide fixture") }
            let deliveredBearing = original.deviceRay(at: subject)
            var mixedFrameError = 0.0
            for index in 0...240 {
                let time = Double(index) / 120
                let prior = simd_quatd(angle: sin(time * 2) * 0.35, axis: SIMD3(0, 1, 0))
                let current = simd_quatd(angle: sin((time + 0.05) * 2) * 0.35, axis: SIMD3(0, 1, 0))
                let zoom = 1 + time * 0.5
                let calibration = TrackingCalibration.fallback(zoom: zoom)
                let oldPoint = original.project(deviceRay: prior.inverse.act(deliveredBearing)).point
                guard let correct = geometry.projection(subjectWorldRay: deliveredBearing, calibration: calibration, pose: current),
                      let mixed = geometry.projection(subject: oldPoint, calibration: calibration, pose: current) else {
                    throw Failure(description: "Delayed frame projection failed")
                }
                let expected = calibration.project(deviceRay: current.inverse.act(desiredWorld))
                try require(hypot(correct.point.x - expected.point.x, correct.point.y - expected.point.y) < 1e-8,
                            "Delivered bearing changed when preview pose/intrinsics advanced")
                mixedFrameError = max(mixedFrameError, Double(hypot(mixed.point.x - correct.point.x, mixed.point.y - correct.point.y)))
            }
            try require(mixedFrameError > 0.03, "Fixture did not expose the old mixed-frame coordinate error")
        }
        try run("scene budgets retain original views and bounded refinement") {
            for complex in [false, true] {
                for constrained in [false, true] {
                    let budget = CompositionSearchBudget(complexScene: complex, constrained: constrained)
                    let broad = CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait],
                        raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3],
                        proposalLimit: budget.coarse)
                    try require(broad.contains(where: \.isUnchangedView), "Faster search omitted original baseline")
                    try require(broad.count >= 12 && broad.count <= budget.coarse, "Invalid coarse search coverage")
                    let refined = CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait],
                        raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3],
                        proposalLimit: budget.refinement, refining: Array(broad.prefix(3)))
                    try require(refined.count <= budget.refinement, "Refinement exceeded budget")
                    try require(budget.coarse <= 128 && budget.refinement <= 128 && budget.aesthetics <= 8,
                                "Unbounded crop batch or quality-model work")
                }
            }
            try require(CompositionSearchBudget.isComplex(group: true, intents: [.group]), "Group lost its larger search")
            try require(CompositionSearchBudget.isComplex(group: false, intents: [.landscape]), "Landscape lost its larger search")
        }
        try run("same-focal-length camera guidance can pan instead of pinning the old center") {
            let hero = subject(rect: CGRect(x: 0.12, y: 0.24, width: 0.25, height: 0.40), kind: .object)
            let cropOnly = CompositionPlanner.proposals(subjects: [hero], intents: [.object], raster: raster(),
                calibration: .fallback(), currentZoom: 1, allowedZooms: [1], proposalLimit: 48)
            let guided = CompositionPlanner.proposals(subjects: [hero], intents: [.object], raster: raster(),
                calibration: .fallback(), currentZoom: 1, allowedZooms: [1], proposalLimit: 48, allowsCameraPan: true)
            try require(cropOnly.allSatisfy { $0.observedFraction >= 0.9999 }, "crop-only mode invented pixels")
            try require(guided.contains { $0.observedFraction < 0.9999 && hypot($0.aimPoint.x - 0.5, $0.aimPoint.y - 0.5) > 0.025 },
                        "camera planner still cannot leave the press-time center")
            try require(guided.allSatisfy { $0.observedFraction >= 0.78 }, "camera guidance relies on excessive unseen scene")
            try require(guided.allSatisfy { CompositionPlanner.visibleFraction($0.expectedSubjectRect) >= 0.98 }, "pan cut the subject")
        }
        try run("polygon coverage records unseen margins without synthesizing pixels") {
            let corners = [CGPoint(x: -0.2, y: 0), CGPoint(x: 0.8, y: 0), CGPoint(x: 0.8, y: 1), CGPoint(x: -0.2, y: 1)]
            try require(abs(CompositionViewSupport.fraction(corners) - 0.8) < 0.000001, "incorrect camera-pan coverage")
            try require(CompositionViewSupport.region(corners) == CGRect(x: 0, y: 0, width: 0.8, height: 1), "observed preview included unseen pixels")
            try require(CompositionViewSupport.fraction([.zero, .zero, .zero, .zero]) == 0, "degenerate frame counted as observed")
            try require(CompositionViewSupport.region([]) == nil, "missing corners created a region")
        }
        try run("analysis of a prior heading cannot authorize the current scene") {
            let identity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
            try require(CompositionSceneFreshness.accepts(sourcePose: identity, currentPose: identity, sourceZoom: 1, currentZoom: 1), "stable scene expired")
            for angle in [0.1, 0.3, 1] {
                try require(!CompositionSceneFreshness.accepts(sourcePose: identity,
                    currentPose: simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)), sourceZoom: 1, currentZoom: 1), "old heading created a target")
            }
            try require(!CompositionSceneFreshness.accepts(sourcePose: identity, currentPose: identity, sourceZoom: 1, currentZoom: 2), "old lens image created a target")
        }
        try run("newly revealed scene must retain the same subject category") {
            let box = CGRect(x: 0.25, y: 0.2, width: 0.45, height: 0.6)
            let human = subject(rect: box, kind: .person)
            let face = CGRect(x: 0.4, y: 0.22, width: 0.1, height: 0.12)
            try require(FinalFramingEvidence.accepts(protectedBounds: box, expectedKind: .person,
                minimumFaces: 1, minimumPeople: 1, subjects: [human], faces: [face]), "same person was rejected")
            try require(!FinalFramingEvidence.accepts(protectedBounds: box, expectedKind: .person,
                minimumFaces: 1, minimumPeople: 1, subjects: [subject(rect: box, kind: .object)], faces: []), "background replaced a person")
            try require(!FinalFramingEvidence.accepts(protectedBounds: box, expectedKind: .group,
                minimumFaces: 3, minimumPeople: 3, subjects: [human], faces: [face]), "one remaining person passed group verification")
        }
        try run("system aesthetics compare real scores without treating utility as failure") {
            let utility = SystemPhotographicAssessment.Score(overall: 0.6, isUtility: true)
            try require(SystemPhotographicAssessment.preservesQuality(candidate: utility, original: utility, zoomRatio: 2), "Utility image discarded")
            try require(!SystemPhotographicAssessment.preservesQuality(candidate: .init(overall: 0.2, isUtility: false), original: utility, zoomRatio: 2), "Large quality loss ignored")
            try require(SystemPhotographicAssessment.preservesQuality(candidate: .init(overall: 0.2, isUtility: false), original: utility, zoomRatio: 1), "Unknown same-focal pan compared as a complete crop")
        }
        try run("unseen-margin pan needs support beyond geometry and conversion noise") {
            try require(!LearnedFramingPolicy.supportsPartlyObservedReframing(
                preference: -1, originalPreference: 1, composition: 2.9, originalComposition: 3,
                aesthetics: 3, originalAesthetics: 3), "Geometry overruled all learned evidence")
            try require(LearnedFramingPolicy.supportsPartlyObservedReframing(
                preference: -1, originalPreference: 1, composition: 3, originalComposition: 3,
                aesthetics: 3, originalAesthetics: 3), "Crop-score source bias alone vetoed a pan")
            try require(LearnedFramingPolicy.supportsPartlyObservedReframing(
                preference: -1, originalPreference: 1, composition: 3.2, originalComposition: 3,
                aesthetics: 3, originalAesthetics: 3), "A composition gain was vetoed by crop-score source bias")
            try require(LearnedFramingPolicy.supportsPartlyObservedReframing(
                preference: 1, originalPreference: 1.001, composition: 3, originalComposition: 3.01,
                aesthetics: 3, originalAesthetics: 3.01), "Numerical noise invented a quality regression")
            try require(!LearnedFramingPolicy.supportsPartlyObservedReframing(
                preference: .nan, originalPreference: 1, composition: 3, originalComposition: 3,
                aesthetics: 3, originalAesthetics: 3), "Nonfinite evidence authorized a pan")
        }
        print("Composition regressions: \(passed) passed")
    }
}
