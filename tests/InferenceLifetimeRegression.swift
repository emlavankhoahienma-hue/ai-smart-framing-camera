import Foundation
import CoreGraphics
import CoreImage
import CoreML
import ImageIO

@main
enum InferenceLifetimeRegression {
    struct Failure: Error { let message: String }

    final class StageFootprints: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [[String: Any]] = []

        func record(_ stage: String) {
            let bytes = CompositionInferenceResources.footprint
            lock.withLock { samples.append(["stage": stage, "footprint": bytes]) }
            print("Production search checkpoint: \(stage); footprint=\(bytes)")
            fflush(stdout)
        }

        var snapshot: [[String: Any]] { lock.withLock { samples } }
    }

    /// Exercises the production search's own stage boundaries. The central box
    /// is an explicit policy fixture, not a claim that a recognizer found an
    /// object there. Raster, Focal importance and all quality scores use the
    /// actual source photograph. No outer pool separates individual models.
    static func productionSearch(file: URL, root: URL,
                                 renderer: CompositionImageRenderer) throws -> [String: Any] {
        let stages = StageFootprints()
        stages.record("before source decode")
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "Cannot decode production-search photograph")
        }
        let ci = CIImage(cgImage: image)
        guard let reference = renderer.referenceImage(ci),
              let baseRaster = renderer.raster(image: ci, saliency: nil) else {
            throw Failure(message: "Cannot measure production-search source pixels")
        }
        let token = CompositionAnalysisCancellation()
        let crop = try autoreleasepool {
            try FocalCropModel(url: root.appendingPathComponent("FocalCrop.mlmodelc"), image: reference)
        }
        guard crop.assess([CGRect(x: 0, y: 0, width: 1, height: 1)], cancellation: token) != nil else {
            throw Failure(message: "Production-search Focal importance failed")
        }
        stages.record("Focal source importance complete")
        let raster = crop.enriching(baseRaster)
        let box = CGRect(x: 0.38, y: 0.34, width: 0.24, height: 0.32)
        let subject = CompositionSubject(index: 0, bounds: box,
            anchor: CGPoint(x: box.midX, y: box.midY), kind: .object,
            confidence: 1, importance: 1, gaze: 0)
        let calibration = TrackingCalibration.fallback(aspect: Double(image.width) / Double(image.height))
        func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: [.object, .street],
                portraitBounds: nil, raster: raster, calibration: calibration, currentZoom: 1,
                allowedZooms: [1, 2, 3], protectedBounds: [box],
                proposalLimit: seeds.isEmpty ? 24 : 12, refining: seeds, allowsCameraPan: true)
        }
        let broad = proposals()
        guard !broad.isEmpty, broad.contains(where: \.isUnchangedView) else {
            throw Failure(message: "Policy fixture lacks an original production proposal")
        }
        stages.record("before production search")
        guard let result = CompositionAestheticSearch(renderer: renderer).run(proposals: broad,
            image: ci, aspect: calibration.aspect, preferences: [:],
            modelURL: root.appendingPathComponent("SAMPComposition.mlmodelc"),
            aestheticModelURL: root.appendingPathComponent("CharmAesthetics.mlmodelc"),
            positionURL: root.appendingPathComponent("CharmPositionEmbedding.bin"),
            aestheticLimit: 3, cropModel: crop, cancellation: token,
            progress: { stages.record($0) }, diagnostic: { stages.record("Diagnostic: \($0)") },
            refine: { proposals($0) }), result.usedSpecialist, !result.views.isEmpty,
            result.assessedCount > 0, result.modernAssessmentCount == result.assessedCount,
            result.cropAssessmentCount >= broad.count,
            result.views.allSatisfy({ $0.assessment != nil && $0.aesthetics != nil }) else {
            throw Failure(message: "Production model search failed for \(file.lastPathComponent)")
        }
        stages.record("production search returned")
        // This probe is deliberately after run(), with a live token. Removing
        // production's releaseInferenceWeights() must fail the test, rather than
        // being masked by a separate test-owned pool between stages.
        guard !token.isCancelled,
              crop.assess([CGRect(x: 0, y: 0, width: 1, height: 1)], cancellation: token) == nil else {
            throw Failure(message: "Production search retained Focal inference weights")
        }
        let samples = stages.snapshot
        return ["photo": file.lastPathComponent,
            "subjectEvidence": "Fixed central protected policy fixture; no recognizer invoked",
            "initialProposals": broad.count, "focalAssessedRegions": result.cropAssessmentCount,
            "sampPredictions": result.assessedCount, "charmPredictions": result.modernAssessmentCount,
            "applePredictions": result.systemAssessmentCount,
            "productionReleasedFocalWeights": true, "stages": samples,
            "maxCheckpointFootprint": samples.compactMap { $0["footprint"] as? UInt64 }.max() ?? 0]
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let photos = root.appendingPathComponent("tests/fixtures/fcdb")
        let files = try FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 12 else { throw Failure(message: "Missing real photograph inputs") }
        let renderer = CompositionImageRenderer()
        var rows: [[String: Any]] = [], settled: [UInt64] = []
        for cycle in 0..<12 {
            let peaks: [UInt64] = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(files[cycle] as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Cannot decode real photo") }
                let token = CompositionAnalysisCancellation()
                let ci = CIImage(cgImage: image)
                let aspect = Double(image.width) / Double(image.height)
                var views: [CGImage] = []
                let scales: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.6, 0.5]
                for scale in scales {
                    let r = CGRect(x: (1 - scale) / 2, y: (1 - scale) / 2, width: scale, height: scale)
                    let corners = [r.origin, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                    guard let preview = renderer.preview(image: ci, corners: corners, aspect: aspect) else { throw Failure(message: "Preview failed") }
                    views.append(preview)
                }
                var peaks: [UInt64] = []
                try autoreleasepool {
                    let crop = try FocalCropModel(url: root.appendingPathComponent("FocalCrop.mlmodelc"), image: image)
                    guard crop.assess([CGRect(x: 0, y: 0, width: 1, height: 1)], cancellation: token) != nil else { throw Failure(message: "Focal failed") }
                    peaks.append(CompositionInferenceResources.footprint)
                    crop.releaseInferenceWeights()
                }
                try autoreleasepool {
                    let model = try PhotographicCompositionModel(url: root.appendingPathComponent("SAMPComposition.mlmodelc"))
                    for view in views {
                        guard model.assess(view, cancellation: token) != nil else { throw Failure(message: "SAMP failed") }
                        peaks.append(CompositionInferenceResources.footprint)
                    }
                }
                try autoreleasepool {
                    let model = try CharmPhotographicModel(url: root.appendingPathComponent("CharmAesthetics.mlmodelc"),
                        positionURL: root.appendingPathComponent("CharmPositionEmbedding.bin"), computeUnits: .cpuOnly)
                    for view in views {
                        guard model.assess(view, cancellation: token) != nil else { throw Failure(message: "Charm failed") }
                        peaks.append(CompositionInferenceResources.footprint)
                    }
                    token.cancel()
                    guard model.assess(views[0], cancellation: token) == nil else { throw Failure(message: "Cancellation ignored") }
                }
                return peaks
            }
            let after = CompositionInferenceResources.footprint
            settled.append(after)
            rows.append(["cycle": cycle, "photo": files[cycle].lastPathComponent,
                "footprintAfterRelease": after, "peakObservedFootprint": peaks.max() ?? after])
            print("Inference lifetime cycle \(cycle): \(after) bytes after release")
            fflush(stdout)
        }
        let baseline = settled[2...4].reduce(0, +) / 3
        let final = settled.suffix(3).reduce(0, +) / 3
        var searchRows: [[String: Any]] = [], searchSettled: [UInt64] = []
        for cycle in 0..<6 {
            var row = try autoreleasepool {
                try productionSearch(file: files[cycle % 3], root: root, renderer: renderer)
            }
            let after = CompositionInferenceResources.footprint
            searchSettled.append(after)
            row["cycle"] = cycle
            row["footprintAfterRelease"] = after
            searchRows.append(row)
            print("Production search lifetime cycle \(cycle): \(after) bytes after release")
            fflush(stdout)
        }
        let searchWarm = searchSettled.prefix(3).reduce(0, +) / 3
        let searchFinal = searchSettled.suffix(3).reduce(0, +) / 3
        let report: [String: Any] = ["scope": "macOS production model wrappers on 12 real photos, plus 6 production CompositionAestheticSearch runs on 3 real photos with an explicit protected policy fixture; not iPhone jetsam reproduction or recognition validation",
            "photos": 12, "focalPredictions": 12, "sampPredictions": 72, "charmCPUOnlyPredictions": 72,
            "warmFootprint": baseline, "finalFootprint": final, "cycles": rows,
            "productionSearchRuns": 6, "productionSearchUniquePhotos": 3,
            "productionSearchWarmFootprint": searchWarm, "productionSearchFinalFootprint": searchFinal,
            "productionSearchCycles": searchRows,
            "memorySamplingScope": "Footprints are measured at checkpoints, not transient allocation peaks. Wrapper counts exclude the separately reported production searches. Production uses its own compute-unit selection; the wrapper-only Charm test forces CPU-only."]
        let output = root.appendingPathComponent("validation/swift/inference-lifetime.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        guard final <= baseline + 160 * 1024 * 1024 else { throw Failure(message: "Sustained memory growth across released analyses") }
        guard searchFinal <= searchWarm + 160 * 1024 * 1024 else {
            throw Failure(message: "Sustained memory growth across production searches")
        }
        print("PASS: repeated real-image wrapper inference, CPU-only Charm, cancellation and 6 production searches with released Focal weights and bounded checkpoint memory")
    }
}
