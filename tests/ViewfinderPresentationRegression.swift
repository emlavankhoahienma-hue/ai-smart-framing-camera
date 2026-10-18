import Foundation
import CoreGraphics

@main
enum ViewfinderPresentationRegression {
    struct Failure: Error { let message: String }
    static var passed = 0

    static func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        if !ok() { throw Failure(message: message) }
    }

    static func run(_ title: String, _ block: () throws -> Void) throws {
        try block()
        passed += 1
        print("PASS: \(title)")
    }

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0000001 }

    static func main() throws {
        try run("preflight outlines the final optical crop without a second closing animation") {
            let geometry = ZoomRevealGeometry(startZoom: 1, targetZoom: 2.4)!
            let crop = geometry.normalizedRect(actualZoom: 1)!
            try require(near(crop.width, 1 / 2.4) && near(crop.midX, 0.5) && near(crop.midY, 0.5), "wrong initial crop")
        }
        try run("stalled lens feedback cannot advance the aperture") {
            let geometry = ZoomRevealGeometry(startZoom: 1, targetZoom: 3)!
            let held = geometry.normalizedRect(actualZoom: 1.2)!
            for _ in 0..<600 {
                try require(geometry.normalizedRect(actualZoom: 1.2) == held, "elapsed time fabricated optical progress")
            }
        }
        try run("every zoom-in aperture predicts the same final photographed field") {
            for start in [CGFloat(0.5), 1, 2, 3] {
                for ratio in [CGFloat(1.15), 1.5, 2.4, 5, 12] {
                    let target = start * ratio
                    let geometry = ZoomRevealGeometry(startZoom: start, targetZoom: target)!
                    for index in 0...120 {
                        let actual = start + (target - start) * CGFloat(index) / 120
                        let crop = geometry.normalizedRect(actualZoom: actual)!
                        try require(near(crop.width / actual, 1 / target), "aperture drifts from the real crop")
                        try require(near(crop.midX, 0.5) && near(crop.midY, 0.5), "aperture drifts away from optical centre")
                    }
                }
            }
        }
        try run("zoom out reveals surroundings without pretending to preview unseen pixels") {
            let geometry = ZoomRevealGeometry(startZoom: 3, targetZoom: 1)!
            try require(geometry.isZoomingOut, "wrong direction")
            try require(geometry.normalizedRect(actualZoom: 3) == CGRect(x: 0, y: 0, width: 1, height: 1), "unseen wider field invented")
            let half = geometry.normalizedRect(actualZoom: 1.5)!
            try require(near(half.width, 0.5) && near(half.width / 1.5, 1 / 3), "original field moves during zoom out")
        }
        try run("small final crops are not inflated by an arbitrary twenty-percent minimum") {
            let crop = ZoomRevealGeometry(startZoom: 0.5, targetZoom: 10)!.normalizedRect(actualZoom: 0.5)!
            try require(near(crop.width, 0.05), "the frame misrepresents a large optical zoom")
        }
        try run("fresh sessions cannot reuse the preceding crop geometry") {
            let first = ZoomRevealGeometry(startZoom: 1, targetZoom: 3)!.normalizedRect(actualZoom: 1)!
            let next = ZoomRevealGeometry(startZoom: 2, targetZoom: 2.5)!.normalizedRect(actualZoom: 2)!
            try require(near(first.width, 1 / 3) && near(next.width, 0.8), "session state leaked into geometry")
            try require(ZoomRevealGeometry(startZoom: 2, targetZoom: 2) == nil, "no-zoom shot got a fake reveal")
        }
        try run("invalid lens values cannot create a NaN frame") {
            for invalid in [CGFloat.nan, .infinity, -.infinity, 0, -1] {
                try require(ZoomRevealGeometry(startZoom: invalid, targetZoom: 2) == nil, "bad starting zoom")
                try require(ZoomRevealGeometry(startZoom: 1, targetZoom: invalid) == nil, "bad target zoom")
                try require(ZoomRevealGeometry(startZoom: 1, targetZoom: 2)!.normalizedRect(actualZoom: invalid) == nil, "bad feedback zoom")
            }
        }
        try run("overshoot stays finite and preserves the optical centre") {
            let rect = ZoomRevealGeometry(startZoom: 1, targetZoom: 2)!.normalizedRect(actualZoom: 2.01)!
            try require(rect == CGRect(x: 0, y: 0, width: 1, height: 1), "overshoot put the aperture outside the optical field")
        }
        try run("aspect-fill projection matches the production target projection") {
            let rect = ZoomRevealGeometry(startZoom: 1, targetZoom: 2)!.normalizedRect(actualZoom: 1)!
            for size in [CGSize(width: 320, height: 426.6666667), CGSize(width: 390, height: 844), CGSize(width: 500, height: 300)] {
                let mapped = ZoomRevealGeometry.screenRect(rect, size: size, bufferAspect: 0.75)!
                let origin = TrackingGeometry.screenPoint(rect.origin, size: size, aspect: 0.75)
                try require(mapped.origin == origin && near(mapped.midX, size.width / 2) && near(mapped.midY, size.height / 2), "mask and subject use different image coordinates")
            }
        }
        try run("invalid viewport cannot create drawing coordinates") {
            let rect = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
            try require(ZoomRevealGeometry.screenRect(rect, size: .zero, bufferAspect: 0.75) == nil, "zero viewport accepted")
            try require(ZoomRevealGeometry.screenRect(rect, size: CGSize(width: 300, height: 400), bufferAspect: .nan) == nil, "invalid aspect accepted")
        }
        try run("guidance line leaves both the fixed ring and moving dot unobscured") {
            let from = CGPoint(x: 100, y: 100), to = CGPoint(x: 160, y: 180)
            let segment = ViewfinderGuideGeometry.segment(from: from, to: to)!
            try require(near(hypot(segment.start.x - from.x, segment.start.y - from.y), 21), "line enters centre ring")
            try require(near(hypot(segment.end.x - to.x, segment.end.y - to.y), 10), "line overlaps target dot")
        }
        try run("coincident and invalid targets never produce an inverted guide") {
            let centre = CGPoint(x: 100, y: 100)
            try require(ViewfinderGuideGeometry.segment(from: centre, to: centre) == nil, "coincident points divided by zero")
            try require(ViewfinderGuideGeometry.segment(from: centre, to: CGPoint(x: 110, y: 110)) == nil, "short line inverted")
            try require(ViewfinderGuideGeometry.segment(from: centre, to: CGPoint(x: CGFloat.nan, y: 0)) == nil, "nonfinite guide accepted")
        }
        try run("zoom progress comes from measured focal change in both directions") {
            let inward = ZoomRevealGeometry(startZoom: 1, targetZoom: 4)!
            let outward = ZoomRevealGeometry(startZoom: 4, targetZoom: 1)!
            try require(near(inward.progress(actualZoom: 2), 0.5), "Wrong inward progress")
            try require(near(outward.progress(actualZoom: 2), 0.5), "Wrong outward progress")
            try require(near(inward.progress(actualZoom: 1), 0), "Command fabricated progress")
            try require(near(inward.progress(actualZoom: 5), 1), "Overshoot escaped progress")
            try require(near(inward.progress(actualZoom: .nan), 0), "Invalid feedback filled progress")
        }
        print("Viewfinder presentation regressions passed: \(passed)")
    }
}
