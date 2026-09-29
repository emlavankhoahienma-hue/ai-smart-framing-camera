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
