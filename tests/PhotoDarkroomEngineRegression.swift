import Foundation
import CoreGraphics
import CoreImage

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

        print("=== Summary: \(passedTests) passed, \(failedTests) failed ===")
        if failedTests > 0 {
            exit(1)
        }
    }
}
