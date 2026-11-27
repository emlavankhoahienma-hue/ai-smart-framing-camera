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
        try run("a composition gain cannot conceal a clear aesthetic regression") {
            try require(!CompositionPreferencePolicy.consistent(composition: 4, aesthetics: 2,
                originalComposition: 3, originalAesthetics: 3), "one model traded away photographic quality")
            try require(CompositionPreferencePolicy.consistent(composition: 3.46, aesthetics: 3.4,
                originalComposition: 3.5, originalAesthetics: 3.1), "small numerical variation vetoed a useful crop")
            try require(!CompositionPreferencePolicy.consistent(composition: .nan, aesthetics: 3,
                originalComposition: 3, originalAesthetics: 3), "invalid scores passed consensus")
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
        try run("two-model evidence can prefer useful zoom without a SAMP-only veto") {
            let original = CompositionPreferencePolicy.score(composition: 3.4, aesthetics: 3.2, geometry: 0.7)!
            let crop = CompositionPreferencePolicy.score(composition: 3.43, aesthetics: 3.5, geometry: 0.8)!
            try require(CompositionPreferencePolicy.prefersCrop(score: crop, original: original), "useful tighter framing vetoed by old 0.10 rating threshold")
            let worse = CompositionPreferencePolicy.score(composition: 3.1, aesthetics: 3.1, geometry: 0.8)!
            try require(!CompositionPreferencePolicy.prefersCrop(score: worse, original: original), "zoom preferred despite both models ranking it lower")
            try require(!CompositionPreferencePolicy.prefersCrop(score: original + 0.001, original: original), "numerical noise authorized zoom")
            try require(CompositionPreferencePolicy.score(composition: .nan, aesthetics: 3, geometry: 0.8) == nil, "nonfinite learned rating admitted")
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
        try run("restored original view participates in the automatic-selection margin") {
            let broad = CompositionPlanner.proposals(subjects: [subject()], intents: [.portrait],
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3], proposalLimit: 36)
            guard let original = broad.first(where: \.isUnchangedView),
                  let near = broad.first(where: { !$0.isUnchangedView && abs(log(Double($0.zoom))) < 0.15 &&
                    hypot($0.aimPoint.x - 0.5, $0.aimPoint.y - 0.5) < 0.065 }) else {
                throw Failure(description: "missing near-original photo fixture")
            }
            let candidates = broad.map { proposal -> CompositionProposal in
                var copy = proposal
                copy.score = proposal.sourceCorners == near.sourceCorners ? 0.94 :
                    (proposal.sourceCorners == original.sourceCorners ? 0.92 : 0.5)
                return copy
            }
            let ci = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
                .cropped(to: CGRect(x: 0, y: 0, width: 216, height: 288))
            guard let result = CompositionAestheticSearch(renderer: CompositionImageRenderer()).run(
                proposals: candidates, image: ci, aspect: 0.75, preferences: [:], modelURL: nil,
                cancellation: CompositionAnalysisCancellation(), progress: { _ in }, refine: { _ in [] }) else {
                throw Failure(description: "missing selection result")
            }
            let scores = result.views.map { $0.proposal.score }
            try require(result.views.contains { $0.proposal.isUnchangedView }, "original option was discarded")
            try require(scores == scores.sorted(by: >), "runner-up margin compared the wrong alternative")
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
            try require(result?.canAutoselect == false && result?.usedSpecialist == false,
                        "fallback promoted geometry to pretrained composition evidence")
            try require(result?.assessedCount == 0, "invented model assessments")
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
        try run("hero ranking prioritizes foreground tabletop objects over tiny distant background people") {
            let tabletop = CGRect(x: 0.36, y: 0.38, width: 0.24, height: 0.32)
            let distantPerson = CGRect(x: 0.48, y: 0.22, width: 0.09, height: 0.26)
            let fgEvidence = SubjectVisualEvidence(attentionDensity: 0.72, attentionShare: 0.45,
                separation: 0.65, detail: 0.60, exposure: 0.85)
            let bgEvidence = SubjectVisualEvidence(attentionDensity: 0.18, attentionShare: 0.06,
                separation: 0.20, detail: 0.25, exposure: 0.80)
            let fgScore = HeroSubjectPolicy.score(bounds: tabletop, kind: .object, confidence: 0.82, evidence: fgEvidence)
            let bgScore = HeroSubjectPolicy.score(bounds: distantPerson, kind: .person, confidence: 0.82, evidence: bgEvidence, hasFace: false)
            try require(fgScore > bgScore, "distant faceless background person outranked foreground tabletop object")
        }
        try run("undersized subjects are tightened wherever they sit and for every subject kind") {
            let scenes: [(CGRect, CompositionSubjectKind, LocalCompositionIntent)] = [
                (CGRect(x: 0.43, y: 0.40, width: 0.12, height: 0.16), .object, .object),
                (CGRect(x: 0.24, y: 0.36, width: 0.12, height: 0.15), .object, .object),
                (CGRect(x: 0.66, y: 0.46, width: 0.12, height: 0.14), .animal, .animal),
                (CGRect(x: 0.42, y: 0.52, width: 0.11, height: 0.11), .object, .food)
            ]
            for (rect, kind, intent) in scenes {
                let plans = CompositionPlanner.proposals(subjects: [subject(rect: rect, kind: kind)], intents: [intent],
                    raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3], proposalLimit: 36)
                guard let baseline = plans.first(where: \.isUnchangedView),
                      let best = plans.max(by: { $0.score < $1.score }) else {
                    throw Failure(description: "missing baseline or ranking for \(intent)")
                }
                try require(CompositionPreferencePolicy.zoomIsNecessary(originalSizeRatio: baseline.sizeRatio),
                            "\(intent): a subject far below its target size was not flagged for zoom")
                try require(best.zoom >= 1.4, "\(intent): best frame stayed wide at \(best.zoom)x for a tiny subject")
                try require(CompositionPreferencePolicy.tightensTowardTarget(sizeRatio: best.sizeRatio, original: baseline.sizeRatio),
                            "\(intent): best frame did not move the subject toward its target size")
            }
        }
        try run("a subject that already fills its target size is not over-zoomed") {
            let rect = CGRect(x: 0.25, y: 0.22, width: 0.50, height: 0.56)
            let plans = CompositionPlanner.proposals(subjects: [subject(rect: rect, kind: .object)], intents: [.object],
                raster: raster(), calibration: .fallback(), currentZoom: 1, allowedZooms: [1, 2, 3], proposalLimit: 36)
            guard let baseline = plans.first(where: \.isUnchangedView),
                  let best = plans.max(by: { $0.score < $1.score }) else {
                throw Failure(description: "missing baseline or ranking for a large subject")
            }
            try require(!CompositionPreferencePolicy.zoomIsNecessary(originalSizeRatio: baseline.sizeRatio),
                        "a well-sized subject was flagged for zoom")
            try require(best.zoom <= 1.35, "a well-sized subject was zoomed to \(best.zoom)x")
        }
        try run("shot-scale prior only authorizes a tighter crop for an undersized subject") {
            try require(CompositionPreferencePolicy.zoomIsNecessary(originalSizeRatio: 0.30), "undersized subject ignored")
            try require(!CompositionPreferencePolicy.zoomIsNecessary(originalSizeRatio: 0.80), "adequate subject flagged")
            try require(!CompositionPreferencePolicy.zoomIsNecessary(originalSizeRatio: .nan), "invalid size flagged")
            try require(CompositionPreferencePolicy.tightensTowardTarget(sizeRatio: 0.45, original: 0.30), "clear tightening rejected")
            try require(!CompositionPreferencePolicy.tightensTowardTarget(sizeRatio: 0.32, original: 0.30), "marginal crop counted as tightening")
            try require(!CompositionPreferencePolicy.tightensTowardTarget(sizeRatio: 2.4, original: 0.30), "overshooting crop counted as tightening")
            let reached = CompositionPreferencePolicy.shotScaleBonus(sizeRatio: 1.0, original: 0.25)
            let halfway = CompositionPreferencePolicy.shotScaleBonus(sizeRatio: 0.625, original: 0.25)
            try require(abs(reached - CompositionPreferencePolicy.shotScaleBonusWeight) < 1e-9, "reaching the target size earned a partial bonus")
            try require(abs(halfway - reached / 2) < 1e-9, "bonus is not proportional to progress")
            try require(CompositionPreferencePolicy.shotScaleBonus(sizeRatio: 0.26, original: 0.25) == 0, "negligible crop earned a bonus")
            try require(CompositionPreferencePolicy.shotScaleBonus(sizeRatio: 2.4, original: 0.25) == 0, "overshoot earned a bonus")
        }
        try run("synchronized saliency S_sync isolates foreground focal depth cluster") {
            let side = 32
            var luma = [Double](repeating: 0.25, count: side * side)
            var attention = [Double](repeating: 0.04, count: side * side)
            var edges = [Double](repeating: 0.05, count: side * side)
            var depth = [Double](repeating: 0.16, count: side * side)
            for y in 0..<side {
                let py = (Double(y) + 0.5) / Double(side)
                for x in 0..<side {
                    let px = (Double(x) + 0.5) / Double(side)
                    let idx = y * side + x
                    // Main hero cluster (asymmetrical 0.18x0.28) on foreground depth plane
                    if (0.34...0.52).contains(px) && (0.36...0.64).contains(py) {
                        luma[idx] = 0.72
                        attention[idx] = 0.90
                        edges[idx] = 0.78
                        depth[idx] = 0.88
                    } else if (0.82...0.94).contains(px) && (0.12...0.26).contains(py) {
                        // Peripheral distant distractor on background plane
                        luma[idx] = 0.85
                        attention[idx] = 0.85
                        edges[idx] = 0.72
                        depth[idx] = 0.14
                    }
                }
            }
            let syncRaster = CompositionRaster(side: side, luminance: luma, attention: attention,
                                               edges: edges, hasAttention: true, foregroundDepth: depth)
            try require(syncRaster.isValid, "synchronized raster became invalid")
            try require(syncRaster.focalDepthPlane > 0.60, "focal depth plane failed to lock onto foreground hero: \(syncRaster.focalDepthPlane)")
            try require(syncRaster.subjectAttentionDominance > 0.20, "low dominance on isolated hero: \(syncRaster.subjectAttentionDominance)")
            let heroSync = syncRaster.value(syncRaster.synchronizedSaliency, at: CGPoint(x: 0.43, y: 0.50))
            let bgSync = syncRaster.value(syncRaster.synchronizedSaliency, at: CGPoint(x: 0.88, y: 0.19))
            try require(heroSync > bgSync * 2.0, "background plane peak was not attenuated in S_sync (\(heroSync) vs \(bgSync))")
            let clusters = syncRaster.extractSynchronizedClusters(minPeak: 0.24, maxClusters: 4)
            try require(!clusters.isEmpty, "connected-components clustering missed clear foreground cluster")
            let primary = clusters[0]
            try require(abs(primary.anchor.x - 0.43) < 0.08 && abs(primary.anchor.y - 0.50) < 0.08,
                        "mean-shift anchor drifted off foreground cluster: \(primary.anchor)")
            try require(abs(primary.bounds.width - 0.36) > 0.04, "cluster fell back to rigid 0.36 square width")
            let renderer = CompositionImageRenderer()
            let warped = renderer.synchronizedSaliencyCrop(from: syncRaster, corners: [
                CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)
            ], side: 224)
            try require(warped?.count == 224 * 224 && (warped?.allSatisfy { $0.isFinite && (0...1).contains($0) } ?? false),
                        "224x224 warped S_sync crop invalid")
        }
        try run("unlocked shortlist and GAIC RoI score support multi-zoom arbitration") {
            let hero = subject(index: 0, rect: CGRect(x: 0.42, y: 0.38, width: 0.16, height: 0.24), kind: .object)
            let edgeTrash = CGRect(x: 0.84, y: 0.14, width: 0.12, height: 0.16)
            let plans = CompositionPlanner.photographicProposals(subject: hero, intents: [.object],
                portraitBounds: nil, raster: raster(distractorX: 0.90), calibration: .fallback(),
                currentZoom: 1.0, allowedZooms: [1.0, 2.0, 3.0],
                incidentalBounds: [edgeTrash], proposalLimit: 40)
            try require(plans.count > 12 && plans.count <= 40, "shortlist count out of unlocked range: \(plans.count)")
            try require(plans.allSatisfy { $0.gaicScore.isFinite && (0...1).contains($0.gaicScore) }, "invalid GAIC score")
            try require((plans.map(\.zoom).max() ?? 1.0) >= 1.8, "multi-zoom sweep failed to reach telephoto candidates")
            let hiGaic = CompositionPreferencePolicy.score(composition: 3.6, aesthetics: 3.6, geometry: 0.75, gaic: 0.92)!
            let loGaic = CompositionPreferencePolicy.score(composition: 3.6, aesthetics: 3.6, geometry: 0.75, gaic: 0.18)!
            try require(hiGaic > loGaic, "GAIC score failed to differentiate aesthetic preference")
        }
        try run("macOS Vision saliency pixelBuffer matches top-left UI orientation") {
            let size = 256
            var rgba = [UInt8](repeating: 14, count: size * size * 4)
            for y in 0..<size {
                for x in 0..<size {
                    let i = (y * size + x) * 4
                    rgba[i + 3] = 255
                    // Paint a bright high-contrast target in top-right (y: 28..100 in top-down buffer = Vision top)
                    if (156..<228).contains(x) && (28..<100).contains(y) {
                        let stripe = ((x / 6 + y / 6) % 2 == 0)
                        rgba[i] = stripe ? 255 : 40
                        rgba[i + 1] = stripe ? 210 : 90
                        rgba[i + 2] = stripe ? 30 : 220
                    }
                }
            }
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let ci = CIImage(cgImage: cg)
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(ciImage: ci, options: [:])
            try handler.perform([req])
            guard let obs = req.results?.first, let obj = obs.salientObjects?.first else {
                throw Failure(description: "VNGenerateAttentionBasedSaliencyImageRequest returned no salient objects")
            }
            let visionCenterX = obj.boundingBox.midX
            let visionCenterTopDownY = 1.0 - obj.boundingBox.midY
            try require(visionCenterX > 0.55 && visionCenterTopDownY < 0.45,
                        "Vision salient object deviated from top-right target: \(obj.boundingBox)")
            let renderer = CompositionImageRenderer()
            guard let measured = renderer.raster(image: ci, saliency: obs.pixelBuffer) else {
                throw Failure(description: "renderer.raster returned nil for Vision saliency buffer")
            }
            var peakIdx = 0
            var peakVal = -1.0
            for (idx, val) in measured.attention.enumerated() where val > peakVal {
                peakVal = val
                peakIdx = idx
            }
            let mapX = (Double(peakIdx % measured.side) + 0.5) / Double(measured.side)
            let mapY = (Double(peakIdx / measured.side) + 0.5) / Double(measured.side)
            try require(abs(mapX - Double(visionCenterX)) < 0.22 && abs(mapY - Double(visionCenterTopDownY)) < 0.22,
                        "attentionMap orientation disagreed with Vision salientObjects: map=(\(mapX),\(mapY)) vision=(\(visionCenterX),\(visionCenterTopDownY))")
        }
        try run("cluster extraction preserves wide edge-touching heroes and dense mega-component cores") {
            let side = 64
            let zeroCount = side * side
            var luma = [Double](repeating: 0.25, count: zeroCount)
            var edges = [Double](repeating: 0.08, count: zeroCount)
            var depthA = [Double](repeating: 0.22, count: zeroCount)
            var attA = [Double](repeating: 0.04, count: zeroCount)
            // Case A: wide foreground subject touching right edge (e.g. close-up snail) + top-left corner speck
            for y in 0..<side {
                for x in 0..<side {
                    let px = (Double(x) + 0.5) / Double(side)
                    let py = (Double(y) + 0.5) / Double(side)
                    let i = y * side + x
                    if px >= 0.56 && px <= 0.99 && py >= 0.10 && py <= 0.88 {
                        attA[i] = 0.86
                        depthA[i] = 0.72
                        luma[i] = 0.75
                        edges[i] = 0.45
                    } else if px <= 0.10 && py <= 0.10 {
                        attA[i] = 0.92
                        depthA[i] = 0.28
                        luma[i] = 0.85
                    }
                }
            }
            let wideRaster = CompositionRaster(side: side, luminance: luma, attention: attA,
                                               edges: edges, hasAttention: true, foregroundDepth: depthA)
            let wideClusters = wideRaster.extractSynchronizedClusters(minPeak: 0.24, maxClusters: 4)
            try require(!wideClusters.isEmpty, "wide edge-touching subject was dropped")
            try require(wideClusters[0].anchor.x > 0.55 && wideClusters[0].bounds.width > 0.24,
                        "wide subject misclassified as side strip or lost to corner speck: \(wideClusters[0])")

            // Case B: oversized mega-component with 5x5 dense center core and single corner spike
            var attB = [Double](repeating: 0.04, count: zeroCount)
            var depthB = [Double](repeating: 0.60, count: zeroCount)
            for y in 0..<side {
                for x in 0..<side {
                    let px = (Double(x) + 0.5) / Double(side)
                    let py = (Double(y) + 0.5) / Double(side)
                    let i = y * side + x
                    let dCenter = hypot(px - 0.50, py - 0.50)
                    if dCenter <= 0.46 {
                        attB[i] = max(0.32, 0.92 - dCenter * 1.1)
                        depthB[i] = 0.74
                    }
                }
            }
            // Single hot pixel spike in bottom-right corner
            attB[(side - 1) * side + (side - 1)] = 1.0
            let megaRaster = CompositionRaster(side: side, luminance: luma, attention: attB,
                                               edges: edges, hasAttention: true, foregroundDepth: depthB)
            let megaClusters = megaRaster.extractSynchronizedClusters(minPeak: 0.24, maxClusters: 4)
            try require(!megaClusters.isEmpty, "mega-component collapsed instead of extracting central core")
            try require(hypot(megaClusters[0].anchor.x - 0.50, megaClusters[0].anchor.y - 0.50) < 0.14 &&
                        megaClusters[0].area <= 0.56,
                        "core extraction failed to isolate central mass peak: \(megaClusters[0])")
        }
        try run("HeroSubjectPolicy suppresses bottom-clipped passersby and edge slivers") {
            let centered = SubjectVisualEvidence(attentionDensity: 0.65, attentionShare: 0.45,
                separation: 0.55, detail: 0.80, exposure: 0.85, foregroundDepth: 0.72, syncAttention: 0.68, depthContrast: 0.24)
            let passerbyEv = SubjectVisualEvidence(attentionDensity: 0.45, attentionShare: 0.05,
                separation: 0.30, detail: 0.70, exposure: 0.85, foregroundDepth: 0.65, syncAttention: 0.45, depthContrast: 0.10)
            let heroPerson = HeroSubjectPolicy.score(bounds: CGRect(x: 0.38, y: 0.22, width: 0.24, height: 0.52),
                kind: .person, confidence: 0.85, evidence: centered, hasFace: true)
            let bottomPasserby = HeroSubjectPolicy.score(bounds: CGRect(x: 0.35, y: 0.86, width: 0.30, height: 0.13),
                kind: .person, confidence: 0.85, evidence: passerbyEv, hasFace: false)
            let centeredObj = HeroSubjectPolicy.score(bounds: CGRect(x: 0.22, y: 0.18, width: 0.54, height: 0.56),
                kind: .object, confidence: 0.72, evidence: centered, hasFace: false)
            let edgeSliver = HeroSubjectPolicy.score(bounds: CGRect(x: 0.88, y: 0.14, width: 0.11, height: 0.72),
                kind: .object, confidence: 0.75, evidence: passerbyEv, hasFace: false)
            try require(bottomPasserby < heroPerson * 0.45 && bottomPasserby < centeredObj * 0.85,
                        "bottom-clipped passerby scored too high: \(bottomPasserby) vs obj=\(centeredObj)")
            try require(edgeSliver < centeredObj * 0.65,
                        "edge sliver scored too high against centered subject: \(edgeSliver) vs \(centeredObj)")
        }
        try run("zoomed proposals >= 1.35x keep aimPoint and sourceCorners safely in bounds") {
            let nearEdge = subject(index: 0, rect: CGRect(x: 0.10, y: 0.40, width: 0.16, height: 0.24), kind: .object)
            let plans = CompositionPlanner.photographicProposals(subject: nearEdge, intents: [.object],
                portraitBounds: nil, raster: raster(), calibration: .fallback(),
                currentZoom: 1.0, allowedZooms: [1.0, 2.0, 3.0], proposalLimit: 36)
            for plan in plans where plan.zoom >= 1.35 {
                try require((0.03...0.97).contains(plan.aimPoint.x) && (0.03...0.97).contains(plan.aimPoint.y),
                            "zoomed proposal had near-OOB aimPoint: \(plan.aimPoint) at zoom \(plan.zoom)")
                try require(plan.sourceCorners.allSatisfy { (-0.045...1.045).contains($0.x) && (-0.045...1.045).contains($0.y) },
                            "zoomed proposal allowed excessive black OOB corner: \(plan.sourceCorners)")
            }
        }
        try run("denseCompositionalWindows and learned GAIC ranking enforce zero-OOB and zoom regularization") {
            let hero = subject(index: 0, rect: CGRect(x: 0.36, y: 0.28, width: 0.22, height: 0.44), kind: .person)
            let companion = CGRect(x: 0.20, y: 0.32, width: 0.14, height: 0.40)
            let incidental = CGRect(x: 0.85, y: 0.16, width: 0.11, height: 0.20)
            let k = TrackingCalibration.fallback()
            let base = CompositionPlanner.photographicProposals(subject: hero, intents: [.portrait, .environmentalPortrait],
                portraitBounds: nil, raster: raster(), calibration: k, currentZoom: 1.0,
                allowedZooms: [1.0, 2.0, 3.0], protectedBounds: [companion], incidentalBounds: [incidental],
                proposalLimit: 36)
            let dense = CompositionPlanner.denseCompositionalWindows(existing: base, calibration: k,
                currentZoom: 1.0, allowedZooms: [1.0, 2.0, 3.0], subjectAnchor: hero.anchor,
                subjectBounds: hero.bounds, protectedBounds: [companion], incidentalBounds: [incidental],
                raster: raster(), maxCount: GAICCompositionModel.maxBoxes)
            try require(dense.contains(where: \.isUnchangedView), "dense window pool dropped baseline")
            try require(dense.count > base.count && dense.count <= GAICCompositionModel.maxBoxes,
                        "dense window pool count unexpected: \(dense.count)")
            for plan in dense {
                try require(plan.sourceCorners.count == 4 && plan.sourceCorners.allSatisfy {
                    (-0.00001...1.00001).contains($0.x) && (-0.00001...1.00001).contains($0.y)
                }, "dense window stepped out of bounds: \(plan.sourceCorners)")
                let future = TrackingCalibration(fx: k.fx * Double(plan.zoom), fy: k.fy * Double(plan.zoom),
                    cx: 0.5, cy: 0.5, aspect: k.aspect)
                let projComp = CompositionPlanner.project(companion, from: k, to: future, rotation: plan.rotation)
                try require(projComp.map { CompositionPlanner.visibleFraction($0) > 0.98 } == true,
                            "dense window clipped protected companion")
                if let projInc = CompositionPlanner.project(incidental, from: k, to: future, rotation: plan.rotation) {
                    let frac = CompositionPlanner.visibleFraction(projInc)
                    try require(frac <= 0.02 || frac >= 0.98, "dense window bisected incidental")
                }
                let box = GAICCompositionModel.normalizedBox(from: plan.sourceCorners)
                try require(box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1 && box.width >= 0.01,
                            "invalid GAIC normalized box \(box)")
            }
            let hi = CompositionPreferencePolicy.score(composition: 3.0, aesthetics: 3.0, geometry: 0.5,
                gaic: 0.90, hasLearnedGAIC: true, zoomRatio: 1.25)!
            let lo = CompositionPreferencePolicy.score(composition: 3.0, aesthetics: 3.0, geometry: 0.5,
                gaic: 0.30, hasLearnedGAIC: true, zoomRatio: 1.25)!
            let overZoom = CompositionPreferencePolicy.score(composition: 3.0, aesthetics: 3.0, geometry: 0.5,
                gaic: 0.90, hasLearnedGAIC: true, zoomRatio: 2.80)!
            try require(hi - lo > 0.10, "learned GAIC still breaks ties cleanly")
            try require(hi > overZoom + 0.05, "excessive digital zoom was not regularized")
            let strongPhotoWeakGaic = CompositionPreferencePolicy.score(composition: 3.0, aesthetics: 3.0, geometry: 0.85,
                gaic: 0.55, hasLearnedGAIC: true, zoomRatio: 1.25)!
            let badCornerHighGaic = CompositionPreferencePolicy.score(composition: 3.0, aesthetics: 3.0, geometry: 0.20,
                gaic: 0.95, hasLearnedGAIC: true, zoomRatio: 1.25)!
            try require(strongPhotoWeakGaic > badCornerHighGaic + 0.10,
                        "GAIC overrode photographic composition rules (\(badCornerHighGaic) vs \(strongPhotoWeakGaic))")
            let sceneryDense = CompositionPlanner.denseCompositionalWindows(
                existing: [],
                calibration: k,
                currentZoom: 1.0,
                allowedZooms: [1.0, 2.0, 3.0],
                subjectAnchor: CGPoint(x: 0.5, y: 0.5),
                subjectBounds: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.55),
                protectedBounds: [CGRect(x: 0.28, y: 0.28, width: 0.44, height: 0.44)],
                intent: .landscape,
                confidence: 0.70,
                raster: raster(),
                maxCount: 72,
                sceneryFallback: true
            )
            try require(sceneryDense.allSatisfy { Double($0.zoom) <= 1.35 && hypot($0.aimPoint.x - 0.5, $0.aimPoint.y - 0.5) <= 0.19 },
                        "scenery fallback produced aggressive off-center corner targets")
        }
        try run("well-sized foreground object in indoor or tabletop scene avoids forced over-zoom and explores prime rungs") {
            let k = TrackingCalibration.fallback()
            let heroRect = CGRect(x: 0.32, y: 0.24, width: 0.36, height: 0.50)
            let hero = CompositionSubject(index: 0, bounds: heroRect, anchor: CGPoint(x: heroRect.midX, y: heroRect.midY),
                kind: .object, confidence: 0.92, importance: 0.90, gaze: 0)
            let hints = CompositionSceneHints.build(
                from: raster(),
                role: .tabletopEnsemble,
                semanticAvoid: EdgeAvoidanceHints(left: 0.30, right: 0.10, top: 0.20, bottom: 0.10)
            )
            let base = CompositionPlanner.photographicProposals(
                subject: hero, intents: [.object], portraitBounds: nil,
                raster: raster(), calibration: k, currentZoom: 1.0, allowedZooms: [1.0, 2.0, 3.0],
                protectedBounds: [heroRect], sceneHints: hints
            )
            try require(base.contains(where: \.isUnchangedView), "tabletop foreground object dropped 1.0x baseline")
            let dense = CompositionPlanner.denseCompositionalWindows(
                existing: base, calibration: k, currentZoom: 1.0, allowedZooms: [1.0, 2.0, 3.0],
                subjectAnchor: hero.anchor, subjectBounds: hero.bounds, protectedBounds: [heroRect],
                intent: .object, confidence: hero.confidence, raster: raster(),
                maxCount: 128, subject: hero, sceneHints: hints
            )
            try require(dense.contains { abs(Double($0.zoom) - 1.20) < 0.02 }, "dense windows missed 1.2x (28mm) prime rung")
            if let topPlan = base.max(by: { $0.score < $1.score }) {
                try require(topPlan.zoom <= 1.35, "well-sized foreground object was forced into excessive zoom (\(topPlan.zoom)x)")
            }
        }
        try run("CameraFramingDirector solves true 3D pan/tilt at 1x, smart zoom-in/out, sky horizon, flower, and corner-sliver rejection") {
            let k = TrackingCalibration.fallback()
            let identityPose = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            let baseRaster = raster()

            // 1. Portrait at center-right looking right -> true 3D pan (NOT dead center 0.5, 0.5!)
            let portraitDet = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.36, y: 0.18, width: 0.32, height: 0.56),
                anchor: CGPoint(x: 0.52, y: 0.30),
                confidence: 0.90, domain: .human, gazeX: 0.45,
                faceBounds: [CGRect(x: 0.46, y: 0.22, width: 0.12, height: 0.15)]
            )
            let portraitRes = CameraFramingDirector.direct(
                detections: [portraitDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["person": 0.08], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(portraitRes.role == .portrait, "expected portrait role, got \(portraitRes.role)")
            try require(portraitRes.destinationPoint.x < 0.42, "right gaze should place portrait on left golden ratio")
            try require(hypot(Double(portraitRes.aimPointInSource.x - 0.5), Double(portraitRes.aimPointInSource.y - 0.5)) > 0.08,
                        "1x portrait target collapsed to dead center \(portraitRes.aimPointInSource)")
            let projAim = k.project(deviceRay: portraitRes.aimWorldRay)
            try require(projAim.isInFront && hypot(Double(projAim.point.x - portraitRes.aimPointInSource.x), Double(projAim.point.y - portraitRes.aimPointInSource.y)) < 1e-4,
                        "aimWorldRay diverged from aimPointInSource")

            // 2a. Distant small animal (within center-zoomable zone) -> Smart Optical Zoom-In >= 2.0x + center-crop safe
            let smallDogCentered = DirectorDetection(
                label: "dog", localizedLabel: "Chú chó",
                boundingBox: CGRect(x: 0.48, y: 0.46, width: 0.14, height: 0.14),
                anchor: nil, confidence: 0.86, domain: .animal
            )
            let dogRes = CameraFramingDirector.direct(
                detections: [smallDogCentered], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["animal": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(dogRes.role == .animal && dogRes.zoomState == .zoomIn, "expected animal ZOOM_IN")
            try require(dogRes.recommendedZoom >= 2.0, "distant animal failed to zoom in: \(dogRes.recommendedZoom)x")
            try require(dogRes.centerCropVisibleFrame.contains(smallDogCentered.boundingBox),
                        "post-zoom center crop \(dogRes.centerCropVisibleFrame) clipped subject \(smallDogCentered.boundingBox)")
            let halfSpan = 0.5 / Double(dogRes.recommendedZoom)
            try require(Double(dogRes.aimPointInSource.x) >= halfSpan - 0.001 && Double(dogRes.aimPointInSource.x) <= 1.0 - halfSpan + 0.001,
                        "zoomed aim drifted outside sensor bounds: \(dogRes.aimPointInSource)")

            // 2b. Off-center distant small animal -> Center-crop geometric cap + explicit "dịch máy rồi mới zoom" guidance
            let smallDogOffCenter = DirectorDetection(
                label: "dog", localizedLabel: "Chú chó",
                boundingBox: CGRect(x: 0.68, y: 0.50, width: 0.14, height: 0.14),
                anchor: nil, confidence: 0.86, domain: .animal
            )
            let offDogRes = CameraFramingDirector.direct(
                detections: [smallDogOffCenter], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["animal": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(offDogRes.requiresPanBeforeZoom && offDogRes.idealZoomAfterPan >= 2.0,
                        "off-center small animal should require pan before full zoom: \(offDogRes)")
            try require(offDogRes.centerCropVisibleFrame.contains(smallDogOffCenter.boundingBox),
                        "off-center immediate zoom \(offDogRes.recommendedZoom)x clipped dog \(smallDogOffCenter.boundingBox) outside \(offDogRes.centerCropVisibleFrame)")
            try require(offDogRes.explanation.contains("dịch máy rồi mới zoom"),
                        "missing pan-before-zoom guidance in explanation: \(offDogRes.explanation)")

            // 3. Dramatic sky + clouds horizon -> 1.0x wide view, tilts UP to place horizon on lower third 0.667
            let skyDet = DirectorDetection(
                label: "sky", localizedLabel: "Bầu trời",
                boundingBox: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.42),
                anchor: nil, confidence: 0.80, domain: .wideNature
            )
            let skyRes = CameraFramingDirector.direct(
                detections: [skyDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["dramatic_clouds": 0.11, "sky": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(skyRes.role == .skyLandscape, "expected skyLandscape role, got \(skyRes.role)")
            try require(abs(skyRes.recommendedZoom - 1.0) < 0.05, "sky landscape should keep 1.0x wide view")
            try require(skyRes.destinationPoint.y > 0.60 && skyRes.aimPointInSource.y < 0.42,
                        "dramatic sky should tilt camera UP (aimY=\(skyRes.aimPointInSource.y), destY=\(skyRes.destinationPoint.y))")

            // 4. Corner headless person sliver next to dominant pizza -> pizza wins!
            let cornerShoulder = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.0, y: 0.0, width: 0.24, height: 0.36),
                anchor: nil, confidence: 0.78, domain: .human
            )
            let giantPizza = DirectorDetection(
                label: "pizza", localizedLabel: "Bánh pizza",
                boundingBox: CGRect(x: 0.18, y: 0.24, width: 0.62, height: 0.56),
                anchor: nil, confidence: 0.94, domain: .food
            )
            let pizzaRes = CameraFramingDirector.direct(
                detections: [cornerShoulder, giantPizza], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["food": 0.10], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(pizzaRes.role == .food && pizzaRes.heroLabel == "pizza",
                        "corner headless shoulder stole dominant pizza: got \(pizzaRes.role) / \(pizzaRes.heroLabel)")

            // 5. Severely cramped close-up portrait -> 0.5x Ultra-Wide zoom-out; balanced group -> stays 1.0x
            let crampedPerson = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.01, y: 0.0, width: 0.85, height: 0.96),
                anchor: CGPoint(x: 0.44, y: 0.18), confidence: 0.92, domain: .human,
                faceBounds: [CGRect(x: 0.30, y: 0.02, width: 0.28, height: 0.28)]
            )
            let crampedRes = CameraFramingDirector.direct(
                detections: [crampedPerson], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["person": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(abs(crampedRes.recommendedZoom - 0.5) < 0.05, "severely cramped portrait should trigger 0.5x, got \(crampedRes.recommendedZoom)")

            let groupA = DirectorDetection(label: "person", localizedLabel: "Người", boundingBox: CGRect(x: 0.16, y: 0.20, width: 0.26, height: 0.58), anchor: nil, confidence: 0.90, domain: .human)
            let groupB = DirectorDetection(label: "person", localizedLabel: "Người", boundingBox: CGRect(x: 0.52, y: 0.22, width: 0.26, height: 0.56), anchor: nil, confidence: 0.88, domain: .human)
            let groupRes = CameraFramingDirector.direct(
                detections: [groupA, groupB], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["group": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(groupRes.role == .group && abs(groupRes.recommendedZoom - 1.0) < 0.05,
                        "well-framed group should stay 1.0x, got \(groupRes.role) @ \(groupRes.recommendedZoom)x")

            // 6. Non-COCO open-world flower detection -> flower role with optical zoom
            let flowerDet = DirectorDetection(
                label: "blossom", localizedLabel: "Cụm hoa",
                boundingBox: CGRect(x: 0.56, y: 0.34, width: 0.24, height: 0.26),
                anchor: nil, confidence: 0.62, domain: .pureFlower
            )
            let flowerRes = CameraFramingDirector.direct(
                detections: [flowerDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["flower_closeup": 0.10], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(flowerRes.role == .flower && flowerRes.recommendedZoom >= 1.45,
                        "open-world blossom should zoom cleanly: \(flowerRes.role) @ \(flowerRes.recommendedZoom)x")

            // 7. Minimalist centered product with clean symmetric background -> NOT shackled to Golden Ratio!
            let watchDet = DirectorDetection(
                label: "watch", localizedLabel: "Đồng hồ đeo tay",
                boundingBox: CGRect(x: 0.35, y: 0.34, width: 0.30, height: 0.32),
                anchor: nil, confidence: 0.91, domain: .object
            )
            let watchRes = CameraFramingDirector.direct(
                detections: [watchDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["single_product": 0.10, "minimalist_space": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(abs(Double(watchRes.destinationPoint.x) - 0.50) < 0.08,
                        "minimalist symmetric object should allow balanced center, got dest=\(watchRes.destinationPoint)")

            // 8. Heavy left-edge clutter avoidance -> steers camera aim away from left clutter
            let vaseDet = DirectorDetection(
                label: "vase", localizedLabel: "Bình hoa",
                boundingBox: CGRect(x: 0.44, y: 0.36, width: 0.22, height: 0.28),
                anchor: nil, confidence: 0.88, domain: .object
            )
            var leftClutterHints = CompositionSceneHints()
            leftClutterHints.avoid = EdgeAvoidanceHints(left: 0.92, right: 0.0, top: 0.0, bottom: 0.0)
            leftClutterHints.hasRichGuidance = true
            let clutterRes = CameraFramingDirector.direct(
                detections: [vaseDet], raster: baseRaster, sceneHints: leftClutterHints,
                semanticAffinities: ["object": 0.08], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(clutterRes.aimPointInSource.x > 0.51,
                        "heavy left edge clutter should steer aim rightward, got aim=\(clutterRes.aimPointInSource)")

            // 9. Cohesive two-item tabletop pair (cake + coffee) -> preserves both together
            let cakeDet = DirectorDetection(
                label: "cake", localizedLabel: "Bánh ngọt",
                boundingBox: CGRect(x: 0.24, y: 0.38, width: 0.24, height: 0.26),
                anchor: nil, confidence: 0.90, domain: .food
            )
            let cupDet = DirectorDetection(
                label: "cup", localizedLabel: "Chiếc cốc",
                boundingBox: CGRect(x: 0.54, y: 0.40, width: 0.20, height: 0.24),
                anchor: nil, confidence: 0.86, domain: .food
            )
            let pairRes = CameraFramingDirector.direct(
                detections: [cakeDet, cupDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["food_spread": 0.10, "food": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(pairRes.role == .food && pairRes.heroBounds.contains(CGPoint(x: cakeDet.boundingBox.midX, y: cakeDet.boundingBox.midY)) &&
                        pairRes.heroBounds.contains(CGPoint(x: cupDet.boundingBox.midX, y: cupDet.boundingBox.midY)),
                        "cohesive tabletop pair should unify both dishes, got \(pairRes.heroLabel) \(pairRes.heroBounds)")

            // 10. Calm water reflection -> mirror horizon symmetry (NOT forced to 1/3 or 2/3)
            let waterRes = CameraFramingDirector.direct(
                detections: [skyDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["water_reflection": 0.11, "landscape": 0.08], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(waterRes.role == .skyLandscape && abs(Double(waterRes.destinationPoint.y) - 0.50) < 0.06,
                        "water reflection should align horizon near mirror symmetry 0.50, got destY=\(waterRes.destinationPoint.y)")

            // 11. Soft deadline & cancellation contract on CompositionAnalysisCancellation
            let shortCancel = CompositionAnalysisCancellation(softTimeoutSeconds: 0.001)
            Thread.sleep(forTimeInterval: 0.01)
            try require(shortCancel.isSoftDeadlineReached && !shortCancel.isCancelled,
                        "soft deadline should trigger graceful early stop without hard cancellation")
            shortCancel.cancel()
            try require(shortCancel.isCancelled, "cancel() must mark cancellation flag")

            // 12. Multi-sensor aspect ratios (9:16, 3:4, 1:1, 4:3) preserve 3D ray consistency & aspect-invariant zoom
            for testAspect in [9.0 / 16.0, 0.75, 1.0, 4.0 / 3.0] {
                let kAspect = TrackingCalibration.fallback(aspect: testAspect)
                let cupWide = DirectorDetection(
                    label: "cup", localizedLabel: "Chiếc cốc",
                    boundingBox: CGRect(x: 0.28, y: 0.42, width: 0.42, height: 0.18),
                    anchor: nil, confidence: 0.88, domain: .food
                )
                let aspectRes = CameraFramingDirector.direct(
                    detections: [cupWide], raster: baseRaster, sceneHints: .neutral,
                    semanticAffinities: ["food": 0.08], neuralProposals: [],
                    calibration: kAspect, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
                )
                let aspectProj = kAspect.project(deviceRay: aspectRes.aimWorldRay)
                try require(aspectProj.isInFront &&
                            hypot(Double(aspectProj.point.x - aspectRes.aimPointInSource.x),
                                  Double(aspectProj.point.y - aspectRes.aimPointInSource.y)) < 1e-4,
                            "multi-aspect (\(testAspect)) aimWorldRay diverged from aimPointInSource")
                try require(aspectRes.recommendedZoom >= 1.15,
                            "aspect-invariant visualSize should zoom cleanly for 7.6% area cup on aspect=\(testAspect), got \(aspectRes.recommendedZoom)x")
            }

            // 13. Real-world recognition anti-hijack guards (skyscraper vs bottom-edge car, hand-held bottle, flower vs banana, waterfall)
            let giantTower = DirectorDetection(
                label: "skyscraper", localizedLabel: "Nhà cao tầng",
                boundingBox: CGRect(x: 0.16, y: 0.03, width: 0.56, height: 0.82),
                anchor: nil, confidence: 0.42, domain: .architecture
            )
            let bottomCarSliver = DirectorDetection(
                label: "car", localizedLabel: "Ô tô",
                boundingBox: CGRect(x: 0.34, y: 0.92, width: 0.22, height: 0.08),
                anchor: nil, confidence: 0.88, domain: .vehicle
            )
            let archRes = CameraFramingDirector.direct(
                detections: [giantTower, bottomCarSliver], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["building": 0.08], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(archRes.role == .architecture && archRes.heroLabel == "skyscraper",
                        "bottom-edge car sliver hijacked dominant skyscraper: got \(archRes.role) / \(archRes.heroLabel)")

            let handHolding = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.12, y: 0.38, width: 0.72, height: 0.60),
                anchor: nil, confidence: 0.90, domain: .human
            )
            let heldBottle = DirectorDetection(
                label: "bottle", localizedLabel: "Chai nước",
                boundingBox: CGRect(x: 0.22, y: 0.20, width: 0.52, height: 0.70),
                anchor: nil, confidence: 0.88, domain: .food
            )
            let heldRes = CameraFramingDirector.direct(
                detections: [handHolding, heldBottle], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["object": 0.08, "food": 0.06], neuralProposals: [],
                calibration: TrackingCalibration.fallback(aspect: 9.0 / 16.0), pose: identityPose,
                currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(heldRes.role == .food && heldRes.heroLabel == "bottle",
                        "headless hand hijacked held bottle: got \(heldRes.role) / \(heldRes.heroLabel)")

            let succulentBanana = DirectorDetection(
                label: "banana", localizedLabel: "Chuối",
                boundingBox: CGRect(x: 0.06, y: 0.10, width: 0.82, height: 0.80),
                anchor: nil, confidence: 0.66, domain: .food
            )
            let yellowFlower = DirectorDetection(
                label: "flower", localizedLabel: "Bông hoa",
                boundingBox: CGRect(x: 0.42, y: 0.42, width: 0.46, height: 0.44),
                anchor: nil, confidence: 0.30, domain: .pureFlower
            )
            let floraRes = CameraFramingDirector.direct(
                detections: [succulentBanana, yellowFlower], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["flower": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(floraRes.role == .flower && floraRes.heroLabel == "flower",
                        "plant-confusable COCO banana hijacked yellow flower: got \(floraRes.role) / \(floraRes.heroLabel)")

            // 14. Close-up face-only selfie guard (must NOT over-zoom 2.5x into nostrils)
            let selfieFace = DirectorDetection(
                label: "human face", localizedLabel: "Khuôn mặt",
                boundingBox: CGRect(x: 0.39, y: 0.26, width: 0.22, height: 0.26),
                anchor: CGPoint(x: 0.50, y: 0.36), confidence: 0.94, domain: .face,
                faceBounds: [CGRect(x: 0.39, y: 0.26, width: 0.22, height: 0.26)]
            )
            let selfieRes = CameraFramingDirector.direct(
                detections: [selfieFace], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["portrait_closeup": 0.10, "person": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(selfieRes.role == .portrait && selfieRes.recommendedZoom <= 1.25,
                        "close-up face-only detection over-zoomed to \(selfieRes.recommendedZoom)x")

            // 15. Distant full-body person on ordinary street -> classified as .portrait & zooms in cleanly (>=1.5x)
            let distantStreetPerson = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.43, y: 0.32, width: 0.14, height: 0.40),
                anchor: CGPoint(x: 0.50, y: 0.38), confidence: 0.89, domain: .human,
                faceBounds: [CGRect(x: 0.47, y: 0.33, width: 0.06, height: 0.07)]
            )
            let streetPortraitRes = CameraFramingDirector.direct(
                detections: [distantStreetPerson], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["street": 0.08, "person": 0.06], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(streetPortraitRes.role == .portrait && streetPortraitRes.recommendedZoom >= 1.45,
                        "distant person on street failed to zoom in: role=\(streetPortraitRes.role) zoom=\(streetPortraitRes.recommendedZoom)x")

            // 16. Bi-directional Zoom-OUT from 2.0x -> 1.0x on sky landscape & cramped portrait
            let k2x = TrackingCalibration.fallback(zoom: 2.0)
            let zoomedSkyRes = CameraFramingDirector.direct(
                detections: [skyDet], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["dramatic_clouds": 0.11, "sky": 0.09], neuralProposals: [],
                calibration: k2x, pose: identityPose, currentZoom: 2.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(abs(zoomedSkyRes.recommendedZoom - 1.0) < 0.06,
                        "sky landscape at 2.0x failed to zoom out to 1.0x: got \(zoomedSkyRes.recommendedZoom)x")

            let oversizedAt2x = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.14, y: 0.06, width: 0.72, height: 0.88),
                anchor: CGPoint(x: 0.50, y: 0.22), confidence: 0.93, domain: .human,
                faceBounds: [CGRect(x: 0.36, y: 0.08, width: 0.28, height: 0.28)]
            )
            let zoomOutPortraitRes = CameraFramingDirector.direct(
                detections: [oversizedAt2x], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["person": 0.09], neuralProposals: [],
                calibration: k2x, pose: identityPose, currentZoom: 2.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(zoomOutPortraitRes.recommendedZoom <= 1.55,
                        "oversized portrait at 2.0x failed to zoom out: got \(zoomOutPortraitRes.recommendedZoom)x")

            // 17. Exact physical actualDest consistency under extreme edge subject + gaze
            let edgeGazePerson = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.66, y: 0.22, width: 0.26, height: 0.56),
                anchor: CGPoint(x: 0.78, y: 0.34), confidence: 0.91, domain: .human, gazeX: 0.48,
                faceBounds: [CGRect(x: 0.72, y: 0.24, width: 0.12, height: 0.14)]
            )
            let edgeGazeRes = CameraFramingDirector.direct(
                detections: [edgeGazePerson], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["person": 0.09], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            let relEdgeZ = Double(edgeGazeRes.recommendedZoom)
            let futureEdgeK = TrackingCalibration(fx: k.fx * relEdgeZ, fy: k.fy * relEdgeZ, cx: k.cx, cy: k.cy, aspect: k.aspect)
            let landed = futureEdgeK.project(deviceRay: edgeGazeRes.rotation.inverse.act(k.deviceRay(at: edgeGazeRes.heroAnchor)))
            try require(landed.isInFront &&
                        hypot(Double(landed.point.x - edgeGazeRes.destinationPoint.x),
                              Double(landed.point.y - edgeGazeRes.destinationPoint.y)) < 1e-3,
                        "destinationPoint lied about clamped post-pan subject position: dest=\(edgeGazeRes.destinationPoint) actual=\(landed.point)")

            // 18. Uniform overcast bright sky must NOT pull camera sideways toward a corner pixel
            let overcastSide = 24
            let overcastLuma = (0..<(overcastSide * overcastSide)).map { idx -> Double in
                let py = (Double(idx / overcastSide) + 0.5) / Double(overcastSide)
                return py < 0.45 ? 0.96 : 0.32
            }
            let overcastRaster = CompositionRaster(
                side: overcastSide, luminance: overcastLuma,
                attention: Array(repeating: 0.1, count: overcastSide * overcastSide),
                edges: Array(repeating: 0.04, count: overcastSide * overcastSide),
                hasAttention: true
            )
            let overcastRes = CameraFramingDirector.direct(
                detections: [skyDet], raster: overcastRaster, sceneHints: .neutral,
                semanticAffinities: ["sky": 0.10], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(abs(Double(overcastRes.aimPointInSource.x) - 0.50) < 0.03,
                        "overcast white sky caused false horizontal pan to \(overcastRes.aimPointInSource)")

            // 19. Very distant full-body person (< 1% area, 16% height) -> NOT dropped by 0.012 area gate, zooms >= 2.5x!
            let tinyDistantPerson = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.47, y: 0.40, width: 0.055, height: 0.16),
                anchor: CGPoint(x: 0.497, y: 0.43), confidence: 0.84, domain: .human
            )
            let tinyPersonRes = CameraFramingDirector.direct(
                detections: [tinyDistantPerson], raster: baseRaster, sceneHints: .neutral,
                semanticAffinities: ["person": 0.06], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(tinyPersonRes.role == .portrait && tinyPersonRes.recommendedZoom >= 2.5,
                        "distant 16%-height person failed to select & zoom: role=\(tinyPersonRes.role) zoom=\(tinyPersonRes.recommendedZoom)x")

            // 20. Orientation-aware unpadLetterbox for rotated portrait (4:3 sensor rotated .right -> 3:4 upright)
            let squareBoxCenter = CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50)
            let unpaddedPortrait = CompositionPureCalculations.unpadLetterbox(
                normalizedRect: squareBoxCenter, sourceWidth: 4032, sourceHeight: 3024, orientation: .right
            )
            try require(abs(unpaddedPortrait.width - (0.50 / 0.75)) < 1e-4 && abs(unpaddedPortrait.height - 0.50) < 1e-4,
                        "oriented portrait unpadLetterbox inverted padX/padY: got \(unpaddedPortrait)")

            // 21. No-clear-subject ambient texture -> preservesOriginalFrame, NO_SUBJECT state, NO false zoom
            let flatRaster = CompositionRaster(
                side: 16,
                luminance: Array(repeating: 0.44, count: 256),
                attention: Array(repeating: 0.08, count: 256),
                edges: Array(repeating: 0.03, count: 256),
                hasAttention: false
            )
            let emptyRes = CameraFramingDirector.direct(
                detections: [], raster: flatRaster, sceneHints: .neutral,
                semanticAffinities: [:], neuralProposals: [],
                calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0]
            )
            try require(emptyRes.role == .scene && emptyRes.zoomState == .noSubject && emptyRes.preservesOriginalFrame,
                        "no-clear-subject scene hallucinated crop/zoom: \(emptyRes)")
            try require(emptyRes.zoomTrace?.reasonCode == .noZoomNoClearSubject,
                        "expected NO_ZOOM_NO_CLEAR_SUBJECT trace, got \(String(describing: emptyRes.zoomTrace?.reasonCode))")

            // 22. Clutter-driven compositional Zoom-In: medium subject surrounded by peripheral distractors zooms cleanly to strip clutter
            let clutteredHero = DirectorDetection(
                label: "motorcycle", localizedLabel: "Xe máy",
                boundingBox: CGRect(x: 0.30, y: 0.36, width: 0.40, height: 0.38),
                anchor: CGPoint(x: 0.50, y: 0.55), confidence: 0.90, domain: .vehicle
            )
            let borderClutter1 = DirectorDetection(
                label: "chair", localizedLabel: "Ghế",
                boundingBox: CGRect(x: 0.01, y: 0.02, width: 0.24, height: 0.26),
                anchor: nil, confidence: 0.80, domain: .furniture
            )
            let borderClutter2 = DirectorDetection(
                label: "car", localizedLabel: "Ô tô",
                boundingBox: CGRect(x: 0.76, y: 0.02, width: 0.23, height: 0.24),
                anchor: nil, confidence: 0.78, domain: .vehicle
            )
            let borderClutter3 = DirectorDetection(
                label: "bottle", localizedLabel: "Chai nước",
                boundingBox: CGRect(x: 0.02, y: 0.78, width: 0.20, height: 0.20),
                anchor: nil, confidence: 0.72, domain: .object
            )
            var clutterHints22 = CompositionSceneHints()
            clutterHints22.avoid = EdgeAvoidanceHints(left: 0.78, right: 0.74, top: 0.82, bottom: 0.65)
            clutterHints22.hasRichGuidance = true
            let clutterZoomRes = CameraFramingDirector.direct(
                detections: [clutteredHero, borderClutter1, borderClutter2, borderClutter3],
                raster: baseRaster, sceneHints: clutterHints22,
                semanticAffinities: ["object": 0.08], neuralProposals: [],
                calibration: TrackingCalibration.fallback(aspect: 1.5), pose: identityPose,
                currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0],
                opticalZooms: [0.5, 1.0, 2.0, 3.0], upscaleThreshold: 3.0
            )
            try require(clutterZoomRes.zoomState.isZoomInFamily && clutterZoomRes.idealZoomAfterPan >= 1.25,
                        "clutter-surrounded medium subject failed to zoom in: state=\(clutterZoomRes.zoomState) zoom=\(clutterZoomRes.recommendedZoom)x trace=\(String(describing: clutterZoomRes.zoomTrace))")
            try require((clutterZoomRes.zoomTrace?.clutterAfter ?? 1.0) < (clutterZoomRes.zoomTrace?.clutterBefore ?? 0.0),
                        "clutter-driven zoom did not reduce clutter score")

            // 23. Border partial-cut penalty awareness: trace accurately detects partial edge cuts and distractor boxes
            try require((clutterZoomRes.zoomTrace?.distractorBoxes.count ?? 0) >= 3,
                        "expected >= 3 distractor boxes tracked in zoomTrace, got \(clutterZoomRes.zoomTrace?.distractorBoxes.count ?? 0)")

            // 24. Temporal stability (EMA fill + dead-band + hysteresis + dwell): 12 jittered frames produce ZERO zoom flicker
            CameraFramingDirector.resetTemporalState()
            var jitterZooms: [CGFloat] = []
            for frameIdx in 0..<12 {
                let dJit = CGFloat((frameIdx % 2 == 0) ? 1 : -1) * 0.012
                let jitterSubject = DirectorDetection(
                    label: "cat", localizedLabel: "Chú mèo",
                    boundingBox: CGRect(x: 0.36 + dJit * 0.5, y: 0.36, width: 0.28 + dJit, height: 0.26 - dJit * 0.5),
                    anchor: CGPoint(x: 0.50, y: 0.45), confidence: 0.88, domain: .animal
                )
                let jRes = CameraFramingDirector.direct(
                    detections: [jitterSubject], raster: baseRaster, sceneHints: .neutral,
                    semanticAffinities: ["animal": 0.09], neuralProposals: [],
                    calibration: k, pose: identityPose, currentZoom: 1.0, allowedZooms: [0.5, 1.0, 2.0, 3.0],
                    enableTemporalHysteresis: true, opticalZooms: [0.5, 1.0, 2.0, 3.0], upscaleThreshold: 3.0
                )
                jitterZooms.append(jRes.recommendedZoom)
            }
            CameraFramingDirector.resetTemporalState()
            let maxJitterSwing = (jitterZooms.max() ?? 1.0) - (jitterZooms.min() ?? 1.0)
            try require(maxJitterSwing <= 0.05,
                        "temporal zoom hysteresis flickered across jittered frames: \(jitterZooms)")

            // 25. Target 3D world-ray projection stability across zoom changes (1.0x -> 1.5x -> 2.0x -> 3.0x -> 1.0x)
            let baseK = TrackingCalibration.fallback(zoom: 1.0, aspect: 0.75)
            let alignedRay = baseK.deviceRay(at: CGPoint(x: 0.5, y: 0.5))
            let offCenterRay = baseK.deviceRay(at: CGPoint(x: 0.60, y: 0.42))
            for zStep in [1.0, 1.5, 2.0, 3.0, 1.0] {
                let zK = TrackingCalibration(
                    fx: baseK.fx * zStep, fy: baseK.fy * zStep,
                    cx: baseK.cx, cy: baseK.cy, aspect: baseK.aspect, isMeasured: baseK.isMeasured
                )
                let pCenter = zK.project(deviceRay: alignedRay)
                try require(pCenter.isInFront && hypot(Double(pCenter.point.x - 0.5), Double(pCenter.point.y - 0.5)) < 1e-5,
                            "aligned target drifted at zoom \(zStep)x: \(pCenter.point)")
                let pOff = zK.project(deviceRay: offCenterRay)
                let expectedOffX = 0.5 + (0.60 - 0.5) * zStep
                let expectedOffY = 0.5 + (0.42 - 0.5) * zStep
                try require(pOff.isInFront &&
                            abs(Double(pOff.point.x) - expectedOffX) < 1e-4 &&
                            abs(Double(pOff.point.y) - expectedOffY) < 1e-4,
                            "off-center target projection jumped at zoom \(zStep)x: got \(pOff.point) expected (\(expectedOffX), \(expectedOffY))")
            }
        }
        print("Composition regressions: \(passed) passed")
    }
}
