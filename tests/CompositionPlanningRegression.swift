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
        print("Composition regressions: \(passed) passed")
    }
}
