import Foundation
import Vision
import ImageIO
import CoreGraphics

@main
enum PortraitPoseDiagnostic {
    static func box(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }
    static func ui(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [[String: Any]] = []
        for file in files {
            let row: [String: Any] = try autoreleasepool {
                let bodies = VNDetectHumanRectanglesRequest()
                bodies.upperBodyOnly = false
                let faces = VNDetectFaceLandmarksRequest()
                let poses = VNDetectHumanBodyPoseRequest()
                try VNImageRequestHandler(url: file, orientation: .up).perform([bodies, faces, poses])
                let faceBoxes = (faces.results ?? []).map { ui($0.boundingBox) }
                let candidates = (bodies.results ?? []).map { ui($0.boundingBox) }
                let valid = candidates.compactMap { PortraitFramingEvidence.bounds(body: $0, faces: faceBoxes, observations: poses.results ?? []) }
                let joints: [[[String: Any]]] = try (poses.results ?? []).map { pose in
                    try pose.recognizedPoints(.all).map { name, point in
                        ["name": String(describing: name), "confidence": Double(point.confidence),
                         "x": Double(point.location.x), "y": Double(1 - point.location.y)]
                    }
                }
                return ["file": file.lastPathComponent, "bodies": candidates.map(box), "faces": faceBoxes.map(box),
                        "poses": joints, "eligible": valid.map(box)]
            }
            records.append(row)
            print("Pose \(records.count)/\(files.count): \(file.lastPathComponent), eligible \((row["eligible"] as? [[Double]])?.count ?? 0)")
            fflush(stdout)
        }
        let eligible = records.filter { !(($0["eligible"] as? [[Double]]) ?? []).isEmpty }.count
        guard files.count == 342, eligible > 0 else { throw CocoaError(.coderInvalidValue) }
        let report: [String: Any] = ["images": records.count, "eligiblePhotos": eligible, "records": records,
            "scope": "Actual Vision body/face/pose observations and production torso eligibility on all CADB human test photos; diagnostic, not aesthetic or phone-performance evaluation"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Pose diagnostic: \(eligible)/\(records.count) photos eligible")
    }
}
