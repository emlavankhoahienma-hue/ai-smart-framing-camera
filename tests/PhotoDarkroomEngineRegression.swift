import Foundation
import CoreGraphics
import CoreImage
import Darwin

private func currentPhysFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), intPtr, &count)
        }
    }
    guard kerr == KERN_SUCCESS else { return 0.0 }
    return Double(info.phys_footprint) / (1024.0 * 1024.0)
}

// MARK: - Pixel Inspection Helpers
private struct RGBAImageData {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(cgImage: CGImage) {
        self.width = cgImage.width
        self.height = cgImage.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: &buf,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        )!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = buf
    }

    func pixel(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let cx = max(0, min(width - 1, x))
        let cy = max(0, min(height - 1, y))
        let off = (cy * width + cx) * 4
        return (
            Double(bytes[off]) / 255.0,
            Double(bytes[off + 1]) / 255.0,
            Double(bytes[off + 2]) / 255.0
        )
    }

    func regionMean(xRange: Range<Int>, yRange: Range<Int>) -> (r: Double, g: Double, b: Double, luma: Double) {
        var sr = 0.0, sg = 0.0, sb = 0.0
        var count = 0
        for y in yRange where y >= 0 && y < height {
            for x in xRange where x >= 0 && x < width {
                let p = pixel(x: x, y: y)
                sr += p.r; sg += p.g; sb += p.b
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0, 0) }
        let r = sr / Double(count)
        let g = sg / Double(count)
        let b = sb / Double(count)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (r, g, b, y)
    }

    static func meanAbsDiff(_ a: RGBAImageData, _ b: RGBAImageData) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1.0 }
        let total = a.width * a.height
        guard total > 0 else { return 0.0 }
        var sum = 0.0
        for i in 0..<total {
            let off = i * 4
            sum += abs(Double(a.bytes[off]) - Double(b.bytes[off]))
            sum += abs(Double(a.bytes[off + 1]) - Double(b.bytes[off + 1]))
            sum += abs(Double(a.bytes[off + 2]) - Double(b.bytes[off + 2]))
        }
        return sum / (Double(total) * 3.0 * 255.0)
    }
}

/// Builds a deterministic 240x180 rich test chart with:
/// - Top-left: vibrant red patch
/// - Top-right: vibrant blue patch
/// - Center-left: mid-gray + dark shadow zone
/// - Center-right: crisp checkerboard + bright specular white light dot
/// - Bottom: warm skin/orange & green foliage swatches
private func makeSyntheticTestChart(width: Int = 240, height: Int = 180) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Neutral dark-mid backdrop
    ctx.setFillColor(red: 0.36, green: 0.36, blue: 0.38, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Note: CGContext has bottom-left origin; RGBAImageData also reads top-down (y=0 top).
    // Fill distinct regions cleanly:
    // Top-left in image coords (high CG y): Vibrant Red
    ctx.setFillColor(red: 0.88, green: 0.16, blue: 0.16, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: height / 2, width: width / 3, height: height / 2))

    // Top-middle: Neutral Mid-Gray (0.50) + Dark Shadow square (0.06)
    ctx.setFillColor(red: 0.50, green: 0.50, blue: 0.50, alpha: 1.0)
    ctx.fill(CGRect(x: width / 3, y: height / 2, width: width / 3, height: height / 2))
    ctx.setFillColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)
    ctx.fill(CGRect(x: width / 3 + 12, y: height / 2 + 12, width: 34, height: 34))

    // Top-right: Vibrant Blue
    ctx.setFillColor(red: 0.14, green: 0.34, blue: 0.90, alpha: 1.0)
    ctx.fill(CGRect(x: 2 * width / 3, y: height / 2, width: width / 3, height: height / 2))

    // Bottom-left: Green foliage swatch
    ctx.setFillColor(red: 0.18, green: 0.72, blue: 0.28, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 2))

    // Bottom-middle: High-contrast checkerboard for sharpness/detail verification
    for row in 0..<6 {
        for col in 0..<6 {
            let bright = ((row + col) % 2) == 0
            ctx.setFillColor(red: bright ? 0.82 : 0.22, green: bright ? 0.82 : 0.22, blue: bright ? 0.82 : 0.22, alpha: 1.0)
            ctx.fill(CGRect(x: width / 3 + col * 12, y: 8 + row * 12, width: 12, height: 12))
        }
    }

    // Bottom-right: Dark scene with bright specular white bulb (for Halation, Bloom, Star)
    ctx.setFillColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
    ctx.fill(CGRect(x: 2 * width / 3, y: 0, width: width / 3, height: height / 2))
    ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    ctx.fillEllipse(in: CGRect(x: 2 * width / 3 + 30, y: 34, width: 18, height: 18))

    return ctx.makeImage()!
}

private var passedTests = 0
private var failedTests = 0

private func check(_ condition: Bool, _ name: String, detail: String = "") {
    if condition {
        passedTests += 1
        print("  [PASS] \(name)\(detail.isEmpty ? "" : " (\(detail))")")
    } else {
        failedTests += 1
        print("  [FAIL] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

@main
struct PhotoDarkroomEngineRegression {
    static func main() {
        print("=== Photo Darkroom Engine & Models Regression Suite ===")
        let engine = PhotoDarkroomRenderEngine.shared
        let chart = makeSyntheticTestChart()
        let baseData = RGBAImageData(cgImage: chart)

        // 1. Identity preservation check
        let idState = PhotoDarkroomEditState()
        let idOut = engine.render(cgImage: chart, state: idState)
        let idData = RGBAImageData(cgImage: idOut)
        let idDiff = RGBAImageData.meanAbsDiff(baseData, idData)
        check(idOut.width == chart.width && idOut.height == chart.height && idDiff < 0.008,
              "1. Identity state preserves exact dimensions & pixels",
              detail: String(format: "diff=%.4f", idDiff))

        // 2. Verify ALL 14 Effects produce real, measurable, physically correct visual changes
        let effectSpecs: [(String, (inout PhotoEffectsState) -> Void)] = [
            ("GRAIN", { $0.grain = 0.85; $0.grainSize = 1.4 }),
            ("VIGNETTE", { $0.vignette = 0.90; $0.vignetteRadius = 1.1 }),
            ("HALATION", { $0.halation = 0.90 }),
            ("BLOOM", { $0.bloom = 0.90; $0.bloomRadius = 14.0 }),
            ("FLARE_SUN", { $0.flare = 0.85; $0.flareStyle = .topLeftSun }),
            ("FLARE_ANAMORPHIC", { $0.flare = 0.85; $0.flareStyle = .anamorphicStreak }),
            ("LEAK", { $0.leak = 0.85; $0.leakPattern = 2 }),
            ("BURN", { $0.burn = 0.85; $0.burnEdge = .left }),
            ("EXPIRED", { $0.expired = 0.85 }),
            ("FADE", { $0.fade = 0.85 }),
            ("DUST", { $0.dust = 0.90; $0.dustSeed = 2 }),
            ("PRISM", { $0.prism = 0.85; $0.prismAxis = .horizontal }),
            ("STAR_4PT", { $0.star = 0.90; $0.starPoints = .four }),
            ("STAR_6PT", { $0.star = 0.90; $0.starPoints = .six }),
            ("DATE", { $0.dateStamp = .classicQuartz })
        ]

        for (name, mutate) in effectSpecs {
            var st = PhotoDarkroomEditState()
            mutate(&st.effects)
            let out = engine.render(cgImage: chart, state: st)
            let data = RGBAImageData(cgImage: out)
            let diff = RGBAImageData.meanAbsDiff(baseData, data)
            check(diff > 0.003, "Effect \(name) produces real measurable pixel output", detail: String(format: "diff=%.4f", diff))
        }

        // Physical direction sanity checks on key effects
        var fadeState = PhotoDarkroomEditState()
        fadeState.effects.fade = 0.85
        let fadeData = RGBAImageData(cgImage: engine.render(cgImage: chart, state: fadeState))
        let baseShadow = baseData.regionMean(xRange: 96..<120, yRange: 44..<70).luma
        let fadeShadow = fadeData.regionMean(xRange: 96..<120, yRange: 44..<70).luma
        check(fadeShadow > baseShadow + 0.04, "FADE genuinely lifts deep shadow black floor",
              detail: String(format: "%.3f -> %.3f", baseShadow, fadeShadow))

        var vigState = PhotoDarkroomEditState()
        vigState.effects.vignette = 0.95
        vigState.effects.vignetteRadius = 1.0
        let vigData = RGBAImageData(cgImage: engine.render(cgImage: chart, state: vigState))
        let cornerDrop = baseData.regionMean(xRange: 2..<18, yRange: 2..<18).luma - vigData.regionMean(xRange: 2..<18, yRange: 2..<18).luma
        let centerDrop = baseData.regionMean(xRange: 105..<135, yRange: 75..<105).luma - vigData.regionMean(xRange: 105..<135, yRange: 75..<105).luma
        check(cornerDrop > centerDrop + 0.03, "VIGNETTE darkens corners strictly more than center",
              detail: String(format: "cornerDrop=%.3f centerDrop=%.3f", cornerDrop, centerDrop))

        // Frame geometry verification (White Border, Black Border, Polaroid Classic)
        var polaroidState = PhotoDarkroomEditState()
        polaroidState.effects.frameStyle = .polaroidClassic
        let polCG = engine.render(cgImage: chart, state: polaroidState)
        check(polCG.width > chart.width && polCG.height > chart.height + (polCG.width - chart.width),
              "FRAME Polaroid expands canvas with taller archival chin margin",
              detail: "\(chart.width)x\(chart.height) -> \(polCG.width)x\(polCG.height)")

        // 3. Verify ALL 12 Tools produce real, directionally accurate transformations
        // 3a. Crop 1:1 + Rotate 90 + Flip + Inscribed Straighten
        var cropSq = PhotoDarkroomEditState()
        cropSq.tools.crop.aspectRatio = .square
        cropSq.tools.crop.normalizedRect = PhotoCropState.centeredNormalizedRect(for: 1.0, imageWidth: 240, imageHeight: 180)
        let sqCG = engine.render(cgImage: chart, state: cropSq)
        check(abs(sqCG.width - sqCG.height) <= 2, "Tool CROP 1:1 produces square output", detail: "\(sqCG.width)x\(sqCG.height)")

        var rotState = PhotoDarkroomEditState()
        rotState.tools.crop.quarterTurns = 1
        let rotCG = engine.render(cgImage: chart, state: rotState)
        check(rotCG.width == chart.height && rotCG.height == chart.width,
              "Tool CROP 90-deg rotation swaps dimensions", detail: "\(rotCG.width)x\(rotCG.height)")

        var flipState = PhotoDarkroomEditState()
        flipState.tools.crop.flipHorizontal = true
        let flipData = RGBAImageData(cgImage: engine.render(cgImage: chart, state: flipState))
        let topLeftAfterFlip = flipData.regionMean(xRange: 10..<50, yRange: 10..<50)
        check(topLeftAfterFlip.b > topLeftAfterFlip.r + 0.30,
              "Tool CROP Flip Horizontal mirrors blue right swatch into top-left",
              detail: String(format: "R=%.2f B=%.2f", topLeftAfterFlip.r, topLeftAfterFlip.b))

        var straightState = PhotoDarkroomEditState()
        straightState.tools.crop.straightenDegrees = 18.0
        let straightData = RGBAImageData(cgImage: engine.render(cgImage: chart, state: straightState))
        let tlCorner = straightData.pixel(x: 1, y: 1)
        let trCorner = straightData.pixel(x: straightData.width - 2, y: 1)
        check((tlCorner.r + tlCorner.g + tlCorner.b) > 0.25 && (trCorner.r + trCorner.g + trCorner.b) > 0.25,
              "Tool CROP Straighten 18 deg has ZERO black corner triangles (inscribed auto-zoom)",
              detail: String(format: "TL=%.2f TR=%.2f", tlCorner.r + tlCorner.g + tlCorner.b, trCorner.r + trCorner.g + trCorner.b))

        // 3b. Exposure Push / Pull
        var pushSt = PhotoDarkroomEditState(); pushSt.tools.exposureEV = 1.2
        var pullSt = PhotoDarkroomEditState(); pullSt.tools.exposureEV = -1.2
        let pushLuma = RGBAImageData(cgImage: engine.render(cgImage: chart, state: pushSt)).regionMean(xRange: 80..<160, yRange: 0..<80).luma
        let pullLuma = RGBAImageData(cgImage: engine.render(cgImage: chart, state: pullSt)).regionMean(xRange: 80..<160, yRange: 0..<80).luma
        check(pushLuma > pullLuma + 0.18, "Tool PUSH/PULL exposure brightens (+) and darkens (-)",
              detail: String(format: "push=%.3f pull=%.3f", pushLuma, pullLuma))

        // 3c. Warmth & Tint direction
        var warmSt = PhotoDarkroomEditState(); warmSt.tools.warmth = 0.85
        var coolSt = PhotoDarkroomEditState(); coolSt.tools.warmth = -0.85
        let warmMid = RGBAImageData(cgImage: engine.render(cgImage: chart, state: warmSt)).regionMean(xRange: 90..<140, yRange: 10..<40)
        let coolMid = RGBAImageData(cgImage: engine.render(cgImage: chart, state: coolSt)).regionMean(xRange: 90..<140, yRange: 10..<40)
        check((warmMid.r - warmMid.b) > (coolMid.r - coolMid.b) + 0.12,
              "Tool WARMTH shifts neutral gray warmer (+) vs cooler (-)",
              detail: String(format: "warm(R-B)=%.3f cool(R-B)=%.3f", warmMid.r - warmMid.b, coolMid.r - coolMid.b))

        var tintSt = PhotoDarkroomEditState(); tintSt.tools.tint = 0.85
        let tintDiff = RGBAImageData.meanAbsDiff(baseData, RGBAImageData(cgImage: engine.render(cgImage: chart, state: tintSt)))
        check(tintDiff > 0.02, "Tool TINT measurably shifts chromatic balance", detail: String(format: "diff=%.4f", tintDiff))

        // 3d. Contrast, Highlights, Shadows, Saturation, Vibrance, Detail
        var desatSt = PhotoDarkroomEditState(); desatSt.tools.saturation = -1.0
        let desatRedPatch = RGBAImageData(cgImage: engine.render(cgImage: chart, state: desatSt)).regionMean(xRange: 10..<55, yRange: 10..<55)
        check(abs(desatRedPatch.r - desatRedPatch.g) < 0.04 && abs(desatRedPatch.g - desatRedPatch.b) < 0.04,
              "Tool SATURATION -100% converts vibrant color to clean monochrome",
              detail: String(format: "RGB=(%.2f,%.2f,%.2f)", desatRedPatch.r, desatRedPatch.g, desatRedPatch.b))

        for (label, mut) in [
            ("CONTRAST", { (t: inout PhotoToolsState) in t.contrast = 0.85 }),
            ("HIGHLIGHTS", { (t: inout PhotoToolsState) in t.highlights = -0.85 }),
            ("SHADOWS", { (t: inout PhotoToolsState) in t.shadows = 0.85 }),
            ("VIBRANCE", { (t: inout PhotoToolsState) in t.vibrance = 0.85 }),
            ("DETAIL", { (t: inout PhotoToolsState) in t.sharpness = 0.85; t.clarity = 0.85 })
        ] {
            var st = PhotoDarkroomEditState()
            mut(&st.tools)
            let d = RGBAImageData.meanAbsDiff(baseData, RGBAImageData(cgImage: engine.render(cgImage: chart, state: st)))
            check(d > 0.005, "Tool \(label) produces real pixel modulation", detail: String(format: "diff=%.4f", d))
        }

        // 3e. Selective 8-Band HSL Isolation Check (Darken Blue without touching Red!)
        var hslSt = PhotoDarkroomEditState()
        hslSt.tools.hsl.blue = PhotoHSLBandValue(hue: 0.0, saturation: 0.0, luminance: -1.0)
        let hslData = RGBAImageData(cgImage: engine.render(cgImage: chart, state: hslSt))
        let baseBlue = baseData.regionMean(xRange: 180..<225, yRange: 10..<55).luma
        let newBlue = hslData.regionMean(xRange: 180..<225, yRange: 10..<55).luma
        let baseRed = baseData.regionMean(xRange: 15..<60, yRange: 10..<55).luma
        let newRed = hslData.regionMean(xRange: 15..<60, yRange: 10..<55).luma
        check((baseBlue - newBlue) > 0.06 && abs(baseRed - newRed) < 0.025,
              "Tool HSL Blue luminance selectively darkens Blue without shifting Red",
              detail: String(format: "blueDrop=%.3f redDrift=%.4f", baseBlue - newBlue, abs(baseRed - newRed)))

        // 3f. 4-Channel Monotone Cubic Hermite Curves (RGB Midtone Lift + Per-Channel Red Boost)
        var curveSt = PhotoDarkroomEditState()
        curveSt.tools.curves.red = PhotoSingleCurve(points: [
            PhotoCurvePoint(x: 0.00, y: 0.00),
            PhotoCurvePoint(x: 0.25, y: 0.42),
            PhotoCurvePoint(x: 0.50, y: 0.78),
            PhotoCurvePoint(x: 0.75, y: 0.92),
            PhotoCurvePoint(x: 1.00, y: 1.00)
        ])
        let lut = curveSt.tools.curves.red.buildLUT(samples: 256)
        let lutValid = lut.count == 256 && lut.allSatisfy { $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }
        let curveGray = RGBAImageData(cgImage: engine.render(cgImage: chart, state: curveSt)).regionMean(xRange: 90..<140, yRange: 10..<40)
        check(lutValid && (curveGray.r - curveGray.b) > 0.16,
              "Tool CURVES per-channel Red monotone spline boosts Red on neutral gray",
              detail: String(format: "R=%.3f B=%.3f", curveGray.r, curveGray.b))

        // 4. Built-in 23 Recipes Integrity + Crop Preservation
        let builtIns = PhotoDarkroomRecipe.builtInRecipes
        let uniqueIDs = Set(builtIns.map(\.id))
        check(builtIns.count == 23 && uniqueIDs.count == 23,
              "Built-in recipes catalog has 23 unique editorial recipes", detail: "count=\(builtIns.count)")
        var croppedSession = PhotoDarkroomEditState()
        croppedSession.tools.crop.aspectRatio = .portrait4x5
        croppedSession.tools.crop.straightenDegrees = 6.5
        let appliedRecipe = builtIns[0].apply(preservingCropFrom: croppedSession)
        check(appliedRecipe.tools.crop == croppedSession.tools.crop && appliedRecipe.activeRecipeID == builtIns[0].id,
              "Applying a Recipe preserves user's active Crop & Straighten")

        // 5. Undo / Redo History Stack
        var history = PhotoDarkroomHistoryStack(maxDepth: 5)
        let s0 = PhotoDarkroomEditState()
        var s1 = s0; s1.tools.exposureEV = 0.5
        var s2 = s1; s2.effects.grain = 0.4
        history.pushUndoSnapshot(s0, newState: s1)
        history.pushUndoSnapshot(s1, newState: s2)
        let u1 = history.undo(current: s2)
        let u0 = history.undo(current: u1 ?? s1)
        let r1 = history.redo(current: u0 ?? s0)
        check(u1 == s1 && u0 == s0 && r1 == s1 && history.canRedo,
              "Undo/Redo stack restores exact snapshots in order")

        // 6. Custom Recipe & Favorites JSON Persistence Round-Trip
        let suiteName = "com.alignai.test.darkroom.\(UUID().uuidString)"
        if let testDefaults = UserDefaults(suiteName: suiteName) {
            let store = PhotoDarkroomRecipeStore(defaults: testDefaults, keyPrefix: "unit")
            let custom = PhotoDarkroomRecipe(
                id: "custom.1",
                name: "SAIGON SUNSET",
                isBuiltIn: false,
                presetRawValue: "Kodak Gold 200",
                filmIntensity: 0.85,
                effects: PhotoEffectsState(grain: 0.3, halation: 0.4, dateStamp: .classicQuartz),
                tools: PhotoToolsState(exposureEV: 0.25, warmth: 0.3, hsl: hslSt.tools.hsl, curves: curveSt.tools.curves)
            )
            _ = store.saveCustomRecipe(custom)
            _ = store.toggleFavoriteFilm("Kodak Gold 200")
            _ = store.toggleFavoriteRecipe("custom.1")
            let loaded = store.loadCustomRecipes()
            let favFilms = store.loadFavoriteFilmRawValues()
            let favRecs = store.loadFavoriteRecipeIDs()
            check(loaded.count == 1 && loaded[0] == custom && favFilms.contains("Kodak Gold 200") && favRecs.contains("custom.1"),
                  "Custom Recipe & Favorites persist losslessly across Codable round-trip")
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        // 7. Histogram Computation & 30-Pass Render Stress Stability
        let hist = PhotoDarkroomHistogram.compute(from: chart)
        check(hist.lumaBins.count == 48 && hist.meanLuminance > 0.1 && hist.meanLuminance < 0.9,
              "Live Histogram produces valid 48-bin RGB + Luma waveform",
              detail: String(format: "meanLuma=%.2f", hist.meanLuminance))

        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<30 {
            var stress = PhotoDarkroomEditState()
            stress.tools.exposureEV = Double(i - 15) * 0.05
            stress.tools.hsl = hslSt.tools.hsl
            stress.tools.curves = curveSt.tools.curves
            stress.effects.grain = 0.35
            stress.effects.halation = 0.40
            stress.effects.bloom = 0.35
            stress.effects.leak = 0.30
            stress.effects.leakPattern = i % 8
            let out = engine.render(cgImage: chart, state: stress, isInteractiveProxy: true)
            if out.width != chart.width { failedTests += 1 }
        }
        engine.clearCaches()
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        check(elapsedMs.isFinite && elapsedMs > 0,
              "30-pass full GPU darkroom stress cycle completes cleanly with cache clear",
              detail: String(format: "total=%.1fms avg=%.1fms/frame", elapsedMs, elapsedMs / 30.0))

        // 8. VideoPreviewMetadata Synced Orientation, Viewport Fit & Formatting
        let portrait90 = VideoPreviewMetadata.orientedSize(
            naturalSize: CGSize(width: 3840, height: 2160),
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        check(abs(portrait90.width - 2160) < 1 && abs(portrait90.height - 3840) < 1,
              "VideoPreviewMetadata orientedSize resolves 90deg portrait 4K track to 2160x3840",
              detail: "\(Int(portrait90.width))x\(Int(portrait90.height))")

        let landscape0 = VideoPreviewMetadata.orientedSize(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )
        check(abs(landscape0.width - 1920) < 1 && abs(landscape0.height - 1080) < 1,
              "VideoPreviewMetadata orientedSize keeps identity landscape 1080p track")

        let stageContainer = CGSize(width: 362, height: 520)
        let fitPortrait = VideoPreviewMetadata.fittedViewportSize(videoSize: portrait90, in: stageContainer)
        check(fitPortrait.width <= stageContainer.width + 0.5 &&
              fitPortrait.height <= stageContainer.height + 0.5 &&
              abs((fitPortrait.width / fitPortrait.height) - (9.0 / 16.0)) < 0.01,
              "VideoPreviewMetadata fits 9:16 portrait video tightly inside stage without letterboxing",
              detail: String(format: "%.1fx%.1f", fitPortrait.width, fitPortrait.height))

        let masterTall = CGSize(width: 2160, height: 4320) // 9:16 + Master Frame footer
        let fitMaster = VideoPreviewMetadata.fittedViewportSize(videoSize: masterTall, in: stageContainer)
        check(fitMaster.width <= stageContainer.width + 0.5 &&
              fitMaster.height <= stageContainer.height + 0.5 &&
              abs((fitMaster.width / fitMaster.height) - 0.5) < 0.01,
              "VideoPreviewMetadata dynamically re-fits Master Frame tall aspect cleanly",
              detail: String(format: "%.1fx%.1f", fitMaster.width, fitMaster.height))

        let fitCinema = VideoPreviewMetadata.fittedViewportSize(videoSize: CGSize(width: 2390, height: 1000), in: stageContainer)
        check(abs(fitCinema.width - stageContainer.width) < 0.5 &&
              abs((fitCinema.width / fitCinema.height) - 2.39) < 0.02,
              "VideoPreviewMetadata fits wide 2.39:1 cinema crop cleanly edge-to-edge")

        let meta4K = VideoPreviewMetadata(
            displaySize: portrait90,
            durationSeconds: 12.4,
            nominalFPS: 59.94,
            codecLabel: "HEVC",
            fileSizeBytes: 29_779_558
        )
        check(meta4K.headerPrimaryLine == "4K · 60fps" &&
              meta4K.headerSecondaryLine == "0:12 · 28.4 MB · HEVC" &&
              meta4K.aspectRatioLabel == "9:16",
              "VideoPreviewMetadata formats 4K 60fps header & metadata accurately",
              detail: "\(meta4K.headerPrimaryLine) | \(meta4K.headerSecondaryLine)")

        check(VideoPreviewMetadata.formatDuration(-3) == "0:00" &&
              VideoPreviewMetadata.formatDuration(.nan) == "0:00" &&
              VideoPreviewMetadata.formatDuration(3725) == "1:02:05",
              "VideoPreviewMetadata duration formatter guards invalid values & hours")

        // 9. Smart QRCodePayloadParser & Vision Sub-Crop Back-Projection
        let parsedWeb = QRCodePayloadParser.parse("https://www.vnexpress.net/thoi-su")
        if case .webURL(let urlStr, let display) = parsedWeb {
            check(urlStr == "https://www.vnexpress.net/thoi-su" && display == "vnexpress.net/thoi-su",
                  "QRCodePayloadParser parses HTTPS web URL cleanly",
                  detail: display)
        } else {
            check(false, "QRCodePayloadParser parses HTTPS web URL cleanly")
        }

        let parsedBare = QRCodePayloadParser.parse("shopee.vn/item/123")
        if case .webURL(let urlStr, let display) = parsedBare {
            check(urlStr == "https://shopee.vn/item/123" && display == "shopee.vn/item/123",
                  "QRCodePayloadParser upgrades bare domain to HTTPS URL")
        } else {
            check(false, "QRCodePayloadParser upgrades bare domain to HTTPS URL")
        }

        let parsedWiFi = QRCodePayloadParser.parse("WIFI:T:WPA;S:Highlands Coffee;P:pass\\;123;H:false;;")
        if case .wifi(let ssid, let pass, let sec, let hidden) = parsedWiFi {
            let qr = DetectedQRCode(rawValue: "wifi", kind: parsedWiFi, normalizedBoundingBox: .zero)
            check(ssid == "Highlands Coffee" && pass == "pass;123" && sec == "WPA" && !hidden &&
                  qr.pillTitle == "Wi-Fi · Highlands Coffee" && qr.copyableText == "pass;123",
                  "QRCodePayloadParser parses Wi-Fi QR including escaped semicolons")
        } else {
            check(false, "QRCodePayloadParser parses Wi-Fi QR including escaped semicolons")
        }

        let vietQRSample = "00020101021238540010A00000072701240006970422011003441972120208QRIBFTTA53037045405500005802VN62180814Coffee AlignAI6304ABCD"
        let parsedVietQR = QRCodePayloadParser.parse(vietQRSample)
        if case .vietQR(let bankName, let accountNumber, let amount, let note, _) = parsedVietQR {
            let qr = DetectedQRCode(rawValue: vietQRSample, kind: parsedVietQR, normalizedBoundingBox: .zero)
            check(bankName == "MB Bank" && accountNumber == "0344197212" &&
                  amount == "50.000đ" && note == "Coffee AlignAI" &&
                  qr.pillTitle == "MB Bank · 50.000đ" && qr.copyableText == "0344197212",
                  "QRCodePayloadParser detects EMVCo VietQR with Vietnam Bank BIN, STK, amount and memo",
                  detail: "\(qr.pillTitle) | STK=\(accountNumber ?? "nil")")
        } else {
            check(false, "QRCodePayloadParser detects EMVCo VietQR with Vietnam Bank BIN, STK, amount and memo")
        }

        let cccdSample = "079095001234|215432109|NGUYEN VAN AN|15081995|Nam|123 Le Loi, Q1, TP.HCM|10052021"
        let parsedCCCD = QRCodePayloadParser.parse(cccdSample)
        if case .cccdVN(let idNum, let fullName, let dob, let gender, let addr, let issue) = parsedCCCD {
            let qr = DetectedQRCode(rawValue: cccdSample, kind: parsedCCCD, normalizedBoundingBox: .zero)
            check(idNum == "079095001234" && fullName == "NGUYEN VAN AN" && dob == "15/08/1995" &&
                  gender == "Nam" && addr == "123 Le Loi, Q1, TP.HCM" && issue == "10/05/2021" &&
                  qr.pillTitle == "CCCD · NGUYEN VAN AN" && qr.copyableText == "079095001234",
                  "QRCodePayloadParser parses Vietnam Chip CCCD 7-field format",
                  detail: "\(qr.pillTitle) | DOB=\(dob)")
        } else {
            check(false, "QRCodePayloadParser parses Vietnam Chip CCCD 7-field format")
        }

        let otpSample = "otpauth://totp/GitHub:dev@align.app?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        let parsedOTP = QRCodePayloadParser.parse(otpSample)
        if case .otpAuth(let issuer, let account, _) = parsedOTP {
            let qr = DetectedQRCode(rawValue: otpSample, kind: parsedOTP, normalizedBoundingBox: .zero)
            check(issuer == "GitHub" && account == "dev@align.app" &&
                  qr.pillTitle == "2FA · GitHub (dev@align.app)",
                  "QRCodePayloadParser parses 2FA otpauth:// TOTP QR",
                  detail: qr.pillTitle)
        } else {
            check(false, "QRCodePayloadParser parses 2FA otpauth:// TOTP QR")
        }

        let geoSample = "geo:10.776900,106.700900?q=Bitexco%20Tower"
        let parsedGeo = QRCodePayloadParser.parse(geoSample)
        if case .geoLocation(let lat, let lon, let label) = parsedGeo {
            let qr = DetectedQRCode(rawValue: geoSample, kind: parsedGeo, normalizedBoundingBox: .zero)
            check(abs(lat - 10.7769) < 1e-4 && abs(lon - 106.7009) < 1e-4 &&
                  label == "Bitexco Tower" && qr.openableURL?.host == "maps.apple.com",
                  "QRCodePayloadParser parses Geo URI with Apple Maps link",
                  detail: qr.pillTitle)
        } else {
            check(false, "QRCodePayloadParser parses Geo URI with Apple Maps link")
        }

        let calSample = "BEGIN:VEVENT\nSUMMARY:Chụp ảnh cưới\nDTSTART:20261201T080000Z\nLOCATION:Nhà thờ Đức Bà\nEND:VEVENT"
        let parsedCal = QRCodePayloadParser.parse(calSample)
        if case .calendarEvent(let title, let startText, let location, _) = parsedCal {
            check(title == "Chụp ảnh cưới" && startText == "20261201T080000Z" && location == "Nhà thờ Đức Bà",
                  "QRCodePayloadParser parses VEVENT calendar QR")
        } else {
            check(false, "QRCodePayloadParser parses VEVENT calendar QR")
        }

        let parsedTel = QRCodePayloadParser.parse("tel:+84901234567")
        let qrTel = DetectedQRCode(rawValue: "tel:+84901234567", kind: parsedTel, normalizedBoundingBox: .zero)
        check(qrTel.openableURL != nil && qrTel.pillTitle == "Gọi +84901234567",
              "QRCodePayloadParser handles actionable tel: deep link")

        let parsedMatmsg = QRCodePayloadParser.parse("MATMSG:TO:support@align.vn;SUB:Gop y;BODY:Xin chao;;")
        if case .deepLink(let mailURL, let label) = parsedMatmsg {
            check(mailURL.hasPrefix("mailto:support@align.vn") && label == "Email",
                  "QRCodePayloadParser converts MATMSG QR to mailto: deep link",
                  detail: mailURL)
        } else {
            check(false, "QRCodePayloadParser converts MATMSG QR to mailto: deep link")
        }

        let parsedMomo = QRCodePayloadParser.parse("momo://app?action=pay")
        if case .deepLink(_, let label) = parsedMomo {
            check(label == "Mở MoMo", "QRCodePayloadParser recognizes Vietnam e-wallet deep links (MoMo)")
        } else {
            check(false, "QRCodePayloadParser recognizes Vietnam e-wallet deep links (MoMo)")
        }

        let parsedVCard = QRCodePayloadParser.parse("BEGIN:VCARD\nVERSION:3.0\nFN:Nguyen Van A\nTEL:0901234567\nEMAIL:a@studio.vn\nEND:VCARD")
        if case .contact(let name, let phone, let email, _) = parsedVCard {
            check(name == "Nguyen Van A" && phone == "0901234567" && email == "a@studio.vn",
                  "QRCodePayloadParser extracts vCard FN, TEL and EMAIL")
        } else {
            check(false, "QRCodePayloadParser extracts vCard FN, TEL and EMAIL")
        }

        let parsedMeCard = QRCodePayloadParser.parse("MECARD:N:Nguyen,An;TEL:0988777666;EMAIL:an@align.vn;;")
        if case .contact(let name, let phone, let email, _) = parsedMeCard {
            check(name == "An Nguyen" && phone == "0988777666" && email == "an@align.vn",
                  "QRCodePayloadParser parses MECARD contact QR cleanly",
                  detail: "\(name) | \(phone ?? "")")
        } else {
            check(false, "QRCodePayloadParser parses MECARD contact QR cleanly")
        }

        let parsedEAN = QRCodePayloadParser.parse("8934563138165", symbologyLabel: "EAN-13")
        if case .productBarcode(let code, let formatLabel) = parsedEAN {
            let qr = DetectedQRCode(rawValue: "8934563138165", kind: parsedEAN, normalizedBoundingBox: .zero, symbologyLabel: "EAN-13")
            check(code == "8934563138165" && formatLabel == "EAN-13" &&
                  qr.openableURL?.absoluteString.contains("8934563138165") == true,
                  "QRCodePayloadParser recognizes 1D EAN-13 product barcode with lookup URL",
                  detail: qr.pillTitle)
        } else {
            check(false, "QRCodePayloadParser recognizes 1D EAN-13 product barcode with lookup URL")
        }

        let parsedPlain = QRCodePayloadParser.parse("Mã giảm giá ALIGN2026")
        if case .plainText(let text) = parsedPlain {
            check(text == "Mã giảm giá ALIGN2026", "QRCodePayloadParser preserves plain text QR")
        } else {
            check(false, "QRCodePayloadParser preserves plain text QR")
        }

        // Vision bottom-left center box (0.25, 0.25, 0.5, 0.5) inside Pass 2 center 56% crop (inset 0.22)
        let subProjected = QRCodePayloadParser.visionRectToFullFrameTopLeft(
            CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50),
            subCropTopLeft: CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.56)
        )
        check(abs(subProjected.midX - 0.5) < 0.001 && abs(subProjected.midY - 0.5) < 0.001 &&
              abs(subProjected.width - 0.28) < 0.001 && abs(subProjected.height - 0.28) < 0.001,
              "QRCodePayloadParser back-projects sub-crop Vision box to exact full-frame top-left rect",
              detail: String(format: "(%.2f,%.2f,%.2f,%.2f)", subProjected.minX, subProjected.minY, subProjected.width, subProjected.height))

        // 10. Multi-QR Selector Anti-Flicker, Tap-to-Pin, Deduplication & Cap Stress Tests
        var selector = QRCodeMultiSelector()
        func makeQR(_ raw: String, cx: CGFloat, cy: CGFloat, w: CGFloat = 0.14) -> DetectedQRCode {
            DetectedQRCode(
                rawValue: raw,
                kind: QRCodePayloadParser.parse(raw),
                normalizedBoundingBox: CGRect(x: cx - w * 0.5, y: cy - w * 0.5, width: w, height: w)
            )
        }

        // 10a. 5 simultaneous cashier QRs with 2 equidistant near center + deterministic hand-shake jitter across 100 frames -> 0 flickers
        let initialBatch = [
            makeQR("https://pay.mb.vn/qr1", cx: 0.46, cy: 0.50),
            makeQR("https://pay.vcb.vn/qr2", cx: 0.54, cy: 0.50),
            makeQR("WIFI:T:WPA;S:Cafe;P:12345678;;", cx: 0.20, cy: 0.25),
            makeQR("https://menu.cafe.vn", cx: 0.80, cy: 0.25),
            makeQR("https://fb.com/cafe", cx: 0.80, cy: 0.78)
        ]
        let firstPick = selector.select(from: initialBatch)
        let lockedFirstRaw = firstPick.primary?.rawValue ?? ""
        var flickerSwitches = 0
        for frameIdx in 0..<100 {
            let jitter = CGFloat(((frameIdx % 2 == 0) ? 1.0 : -1.0)) * 0.014
            let jitteredBatch = [
                makeQR("https://pay.mb.vn/qr1", cx: 0.46 + jitter, cy: 0.50 - jitter * 0.5),
                makeQR("https://pay.vcb.vn/qr2", cx: 0.54 + jitter, cy: 0.50 + jitter * 0.5),
                makeQR("WIFI:T:WPA;S:Cafe;P:12345678;;", cx: 0.20, cy: 0.25),
                makeQR("https://menu.cafe.vn", cx: 0.80, cy: 0.25),
                makeQR("https://fb.com/cafe", cx: 0.80, cy: 0.78)
            ]
            let res = selector.select(from: jitteredBatch)
            if res.primary?.rawValue != lockedFirstRaw {
                flickerSwitches += 1
            }
        }
        check(firstPick.allCodes.count == 5 && flickerSwitches == 0,
              "QRCodeMultiSelector holds primary QR with 0 flicker switches across 100 jittered 5-QR frames",
              detail: "all=\(firstPick.allCodes.count) switches=\(flickerSwitches)")

        // 10b. Explicit user tap-to-pin on edge QR #4 stays 100% locked while visible, falls back cleanly when removed
        selector.pin(rawValue: "https://menu.cafe.vn")
        var pinKeptAllFrames = true
        for frameIdx in 0..<30 {
            let j = CGFloat(frameIdx % 3 - 1) * 0.01
            let res = selector.select(from: [
                makeQR("https://pay.mb.vn/qr1", cx: 0.50, cy: 0.50),
                makeQR("https://menu.cafe.vn", cx: 0.82 + j, cy: 0.22)
            ])
            if res.primary?.rawValue != "https://menu.cafe.vn" || !res.isUserPinned {
                pinKeptAllFrames = false
            }
        }
        let afterEdgeLeft = selector.select(from: [makeQR("https://pay.mb.vn/qr1", cx: 0.50, cy: 0.50)])
        check(pinKeptAllFrames && afterEdgeLeft.primary?.rawValue == "https://pay.mb.vn/qr1" && !afterEdgeLeft.isUserPinned,
              "QRCodeMultiSelector preserves tap-to-pin on edge QR and falls back cleanly when it leaves frame")

        // 10c. Deduplication + hard cap at 8 simultaneous QRs + suppression promotes next QR
        var crowdBatch: [DetectedQRCode] = []
        for idx in 0..<11 {
            crowdBatch.append(makeQR("https://crowd.vn/q\(idx)", cx: 0.12 + CGFloat(idx % 5) * 0.18, cy: 0.20 + CGFloat(idx / 5) * 0.25))
        }
        crowdBatch.append(makeQR("https://crowd.vn/q0", cx: 0.50, cy: 0.50)) // duplicate payload closer to center
        var capSelector = QRCodeMultiSelector()
        let crowdRes = capSelector.select(from: crowdBatch)
        let uniqueCrowdRaws = Set(crowdRes.allCodes.map(\.rawValue))
        let suppressedRes = capSelector.select(from: crowdRes.allCodes, suppressedRawValue: crowdRes.primary?.rawValue)
        check(crowdRes.allCodes.count == 8 && uniqueCrowdRaws.count == 8 &&
              suppressedRes.primary != nil && suppressedRes.primary?.rawValue != crowdRes.primary?.rawValue,
              "QRCodeMultiSelector deduplicates, caps at 8, and promotes next QR on dismiss",
              detail: "capped=\(crowdRes.allCodes.count) next=\(suppressedRes.primary?.rawValue ?? "nil")")

        // 11. Thermal Cadence & Idle GPU Fallback Gating Policy Verification
        let nomIdle = QRThermalCadencePolicy.scanInterval(thermal: .nominal, hasActiveDetection: false) ?? 0
        let fairIdle = QRThermalCadencePolicy.scanInterval(thermal: .fair, hasActiveDetection: false) ?? 0
        let serIdle = QRThermalCadencePolicy.scanInterval(thermal: .serious, hasActiveDetection: false) ?? 0
        let critIdle = QRThermalCadencePolicy.scanInterval(thermal: .critical, hasActiveDetection: false)
        check(nomIdle > 0 && nomIdle < fairIdle && fairIdle < serIdle && critIdle == nil,
              "QRThermalCadencePolicy throttles scan cadence monotonically under thermal load & pauses at critical",
              detail: String(format: "nom=%.3fs fair=%.3fs ser=%.3fs crit=nil", nomIdle, fairIdle, serIdle))

        let nomFallbackTicks = (1...60).filter { QRThermalCadencePolicy.fallbackPassKind(thermal: .nominal, missCounter: UInt64($0)) != 0 }.count
        let fairFallbackTicks = (1...60).filter { QRThermalCadencePolicy.fallbackPassKind(thermal: .fair, missCounter: UInt64($0)) != 0 }.count
        let serFallbackTicks = (1...60).filter { QRThermalCadencePolicy.fallbackPassKind(thermal: .serious, missCounter: UInt64($0)) != 0 }.count
        check(nomFallbackTicks == 20 && fairFallbackTicks == 12 && serFallbackTicks == 0,
              "QRThermalCadencePolicy gates idle GPU fallback passes (>=66% nominal reduction, 0% serious)",
              detail: "nom=\(nomFallbackTicks)/60 fair=\(fairFallbackTicks)/60 ser=\(serFallbackTicks)/60")

        // 12. High-Load Stress Benchmarks (1,000-Cycle Multi-QR + 50-Pass GPU Darkroom Mach phys_footprint Stability)
        let qrStressSamples = [vietQRSample, cccdSample, otpSample, geoSample, calSample, "https://www.apple.com/vn/iphone"]
        let qrWarmupFootMB = currentPhysFootprintMB()
        let qrStartClock = CFAbsoluteTimeGetCurrent()
        var stressSelector = QRCodeMultiSelector()
        var totalSelected = 0
        for cycle in 0..<1000 {
            autoreleasepool {
                var batch: [DetectedQRCode] = []
                batch.reserveCapacity(qrStressSamples.count)
                for (i, raw) in qrStressSamples.enumerated() {
                    let kind = QRCodePayloadParser.parse(raw)
                    let cx = 0.20 + CGFloat(i) * 0.12 + CGFloat((cycle % 3) - 1) * 0.005
                    batch.append(DetectedQRCode(rawValue: raw, kind: kind, normalizedBoundingBox: CGRect(x: cx, y: 0.42, width: 0.12, height: 0.12)))
                }
                if stressSelector.select(from: batch).primary != nil {
                    totalSelected += 1
                }
            }
        }
        let qrElapsedMs = (CFAbsoluteTimeGetCurrent() - qrStartClock) * 1000.0
        let qrEndFootMB = currentPhysFootprintMB()
        let qrGrowthMB = qrEndFootMB - qrWarmupFootMB
        check(totalSelected == 1000 && qrElapsedMs < 1200.0 && qrGrowthMB < 12.0,
              "Stress: 1,000-cycle multi-QR parse + select (6,000 parses) stays fast & leak-free",
              detail: String(format: "%.1fms ram=%.1f->%.1fMB (delta=%+.2fMB)", qrElapsedMs, qrWarmupFootMB, qrEndFootMB, qrGrowthMB))

        // GPU Darkroom 50-Pass Sustained Stress + Cache Flush (Mach phys_footprint growth bound)
        var heavyPresetA = PhotoDarkroomEditState()
        heavyPresetA.effects.grain = 0.70
        heavyPresetA.effects.vignette = 0.65
        heavyPresetA.effects.halation = 0.55
        heavyPresetA.effects.bloom = 0.50
        heavyPresetA.tools.exposureEV = 0.25
        heavyPresetA.tools.sharpness = 0.45
        heavyPresetA.tools.clarity = 0.30

        var heavyPresetB = PhotoDarkroomEditState()
        heavyPresetB.effects.fade = 0.60
        heavyPresetB.effects.expired = 0.55
        heavyPresetB.effects.flare = 0.45
        heavyPresetB.tools.saturation = 0.22
        heavyPresetB.tools.hsl.blue = PhotoHSLBandValue(hue: 0.0, saturation: 0.15, luminance: -0.25)

        // Warmup 10 GPU passes to settle Metal/CoreImage driver pools
        for i in 0..<10 {
            autoreleasepool {
                _ = engine.render(cgImage: chart, state: i.isMultiple(of: 2) ? heavyPresetA : heavyPresetB)
            }
        }
        engine.clearCaches()
        let gpuPostWarmupMB = currentPhysFootprintMB()
        var gpuPeakMB = gpuPostWarmupMB
        let gpuStartClock = CFAbsoluteTimeGetCurrent()
        for pass in 0..<40 {
            autoreleasepool {
                let st = pass.isMultiple(of: 2) ? heavyPresetA : heavyPresetB
                let out = engine.render(cgImage: chart, state: st)
                if out.width == 0 || out.height == 0 {
                    failedTests += 1
                }
            }
            if (pass + 1).isMultiple(of: 10) {
                engine.clearCaches()
            }
            let curMB = currentPhysFootprintMB()
            if curMB > gpuPeakMB { gpuPeakMB = curMB }
        }
        engine.clearCaches()
        let gpuEndMB = currentPhysFootprintMB()
        let gpuElapsedMs = (CFAbsoluteTimeGetCurrent() - gpuStartClock) * 1000.0
        let gpuNetGrowthMB = gpuEndMB - gpuPostWarmupMB
        check(gpuNetGrowthMB < 25.0,
              "Stress: 50-pass GPU Darkroom + clearCaches() holds steady Mach phys_footprint without runaway leak",
              detail: String(format: "%.1fms postWarmup=%.1fMB end=%.1fMB peak=%.1fMB delta=%+.2fMB",
                             gpuElapsedMs, gpuPostWarmupMB, gpuEndMB, gpuPeakMB, gpuNetGrowthMB))

        // 13. First-Launch Permission Onboarding State Machine Verification
        var perm = AppPermissionSnapshot()
        check(perm.shouldPresentPermissionGate && !perm.canEnterCamera &&
              perm.grantedCount == 0 && perm.nextPendingPermission == .camera &&
              perm.primaryCTATitle == "Tiếp tục & Cấp quyền",
              "AppPermissionSnapshot gates fresh install and starts with Camera first")

        perm.setState(.granted, for: .camera)
        check(perm.canEnterCamera && perm.grantedCount == 1 &&
              perm.shouldPresentPermissionGate && perm.nextPendingPermission == .photos &&
              perm.primaryCTATitle == "Cấp quyền Thư viện ảnh",
              "AppPermissionSnapshot advances sequentially to Photos after Camera granted")

        perm.setState(.limited, for: .photos)
        check(perm.photos.isSatisfied && perm.grantedCount == 2 &&
              perm.nextPendingPermission == .microphone &&
              perm.primaryCTATitle == "Cấp quyền Micro",
              "AppPermissionSnapshot treats iOS Limited Photos as satisfied and advances to Microphone")

        perm.setState(.granted, for: .microphone)
        check(perm.isAllSatisfied && abs(perm.completionFraction - 1.0) < 1e-6 &&
              perm.nextPendingPermission == nil && !perm.shouldPresentPermissionGate &&
              perm.primaryCTATitle == "Bắt đầu chụp",
              "AppPermissionSnapshot reaches 3/3 ready state cleanly")

        let deniedCam = AppPermissionSnapshot(camera: .denied, photos: .granted, microphone: .granted, hasCompletedOnboarding: true)
        check(deniedCam.shouldPresentPermissionGate && !deniedCam.canEnterCamera &&
              deniedCam.camera.needsSettingsRedirect && deniedCam.primaryCTATitle == "Mở Cài đặt Camera",
              "AppPermissionSnapshot redirects to Settings when required Camera access is denied")

        let returningPartial = AppPermissionSnapshot(camera: .granted, photos: .notDetermined, microphone: .denied, hasCompletedOnboarding: true)
        check(!returningPartial.shouldPresentPermissionGate && returningPartial.canEnterCamera,
              "AppPermissionSnapshot lets returning users with Camera granted bypass gate cleanly")

        // 14. Still-Photo Gallery Long-Press QR Geometry & Hit-Testing Verification
        let vpSize = CGSize(width: 400, height: 600)
        let landscapeImg = CGSize(width: 4000, height: 3000) // fits to 400x300 centered at y=150..450
        let fitRect = StillPhotoQRGeometry.fittedImageRect(imageSize: landscapeImg, in: vpSize)
        check(abs(fitRect.minX - 0) < 0.5 && abs(fitRect.minY - 150) < 0.5 &&
              abs(fitRect.width - 400) < 0.5 && abs(fitRect.height - 300) < 0.5,
              "StillPhotoQRGeometry computes exact aspectFit rect inside photo viewport",
              detail: String(format: "(%.0f,%.0f,%.0f,%.0f)", fitRect.minX, fitRect.minY, fitRect.width, fitRect.height))

        let normCenter = StillPhotoQRGeometry.normalizedImagePoint(
            fromViewportLocation: CGPoint(x: 200, y: 300),
            viewportSize: vpSize,
            imageSize: landscapeImg,
            zoomScale: 1.0,
            panOffset: .zero
        )
        check(normCenter != nil && abs(normCenter!.x - 0.5) < 1e-4 && abs(normCenter!.y - 0.5) < 1e-4,
              "StillPhotoQRGeometry maps unzoomed center touch to (0.5, 0.5)")

        // Touch in black top letterbox bar (y = 40 < 150) returns nil
        let letterboxMiss = StillPhotoQRGeometry.normalizedImagePoint(
            fromViewportLocation: CGPoint(x: 200, y: 40),
            viewportSize: vpSize,
            imageSize: landscapeImg,
            zoomScale: 1.0,
            panOffset: .zero
        )
        check(letterboxMiss == nil, "StillPhotoQRGeometry ignores touches outside photo letterbox bars")

        // Exact inverse under 2.5x zoom + panOffset (50, -30):
        // Suppose normalized target = (0.75, 0.25) -> unzoomed = (300, 225)
        // Forward screen pt = (200 + (300-200)*2.5 + 50, 300 + (225-300)*2.5 - 30) = (500, 82.5)
        let zoomedNorm = StillPhotoQRGeometry.normalizedImagePoint(
            fromViewportLocation: CGPoint(x: 500, y: 82.5),
            viewportSize: vpSize,
            imageSize: landscapeImg,
            zoomScale: 2.5,
            panOffset: CGSize(width: 50, height: -30)
        )
        check(zoomedNorm != nil && abs(zoomedNorm!.x - 0.75) < 1e-4 && abs(zoomedNorm!.y - 0.25) < 1e-4,
              "StillPhotoQRGeometry inverts 2.5x zoom + pan offset accurately to exact photo point",
              detail: zoomedNorm.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "nil")

        let edgeCrop = StillPhotoQRGeometry.normalizedTouchCropRect(around: CGPoint(x: 0.96, y: 0.04), sideFraction: 0.42)
        check(edgeCrop.minX >= 0 && edgeCrop.minY >= 0 && edgeCrop.maxX <= 1.0001 && edgeCrop.maxY <= 1.0001 &&
              abs(edgeCrop.width - 0.42) < 1e-4 && edgeCrop.contains(CGPoint(x: 0.96, y: 0.04)),
              "StillPhotoQRGeometry clamps corner touch crop rect cleanly within [0, 1]")

        let qrTopLeft = makeQR("https://left.vn", cx: 0.20, cy: 0.25, w: 0.12)
        let qrBotRight = makeQR("https://right.vn", cx: 0.80, cy: 0.78, w: 0.12)
        let hitDirect = StillPhotoQRGeometry.hitTest(normalizedPoint: CGPoint(x: 0.21, y: 0.24), in: [qrTopLeft, qrBotRight])
        let hitNearEdge = StillPhotoQRGeometry.hitTest(normalizedPoint: CGPoint(x: 0.89, y: 0.78), in: [qrTopLeft, qrBotRight], padding: 0.075)
        let hitEmptySky = StillPhotoQRGeometry.hitTest(normalizedPoint: CGPoint(x: 0.50, y: 0.50), in: [qrTopLeft, qrBotRight], padding: 0.075)
        check(hitDirect?.rawValue == "https://left.vn" &&
              hitNearEdge?.rawValue == "https://right.vn" &&
              hitEmptySky == nil,
              "StillPhotoQRGeometry hits direct & thumb-padded QR boxes while rejecting empty photo regions")

        print("=== Summary: \(passedTests) passed, \(failedTests) failed ===")
        if failedTests > 0 {
            exit(1)
        }
    }
}
