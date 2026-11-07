import CoreGraphics
import CoreVideo
import Foundation
import Metal
import simd

/// Metal Compute + Unified Memory accelerator for structure-tensor corner scoring
/// and batch 7x7 ZNCC patch matching on iPhone GPUs (A12 Bionic – A18 Pro).
/// Automatically falls back to SIMD8<Float> CPU vectorization when GPU is busy or unavailable.
final class TargetPatchFlowMetalEngine: @unchecked Sendable {
    static let shared = TargetPatchFlowMetalEngine()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let cornerPipeline: MTLComputePipelineState?

    private static let mslSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CornerGridParams {
        uint width;
        uint height;
        uint left;
        uint right;
        uint top;
        uint bottom;
    };

    kernel void patchFlowCornerResponseKernel(
        device const uchar* pixels [[buffer(0)]],
        device float4* cellBestOut [[buffer(1)]],
        constant CornerGridParams& params [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= 4 || gid.y >= 4) return;
        uint spanX = params.right - params.left;
        uint spanY = params.bottom - params.top;
        uint x0 = params.left + (spanX * gid.x) / 4;
        uint x1 = params.left + (spanX * (gid.x + 1)) / 4;
        uint y0 = params.top + (spanY * gid.y) / 4;
        uint y1 = params.top + (spanY * (gid.y + 1)) / 4;

        float bestScore = 0.0f;
        float bestX = 0.0f;
        float bestY = 0.0f;
        uint w = params.width;
        uint h = params.height;

        for (uint y = y0; y < y1; y += 2) {
            if (y < 4 || y + 4 >= h) continue;
            for (uint x = x0; x < x1; x += 2) {
                if (x < 4 || x + 4 >= w) continue;
                float sxx = 0.0f;
                float syy = 0.0f;
                float sxy = 0.0f;
                for (int v = -1; v <= 1; ++v) {
                    uint row = (uint)((int)y + v) * w;
                    uint rowPrev = (uint)((int)y + v - 1) * w;
                    uint rowNext = (uint)((int)y + v + 1) * w;
                    for (int u = -1; u <= 1; ++u) {
                        uint col = (uint)((int)x + u);
                        float ix = 0.5f * (float(pixels[row + col + 1]) - float(pixels[row + col - 1]));
                        float iy = 0.5f * (float(pixels[rowNext + col]) - float(pixels[rowPrev + col]));
                        sxx += ix * ix;
                        syy += iy * iy;
                        sxy += ix * iy;
                    }
                }
                float trace = sxx + syy;
                float diff = sxx - syy;
                float disc = sqrt(max(0.0f, diff * diff + 4.0f * sxy * sxy));
                float minEigen = 0.5f * (trace - disc);
                if (minEigen > bestScore) {
                    bestScore = minEigen;
                    bestX = float(x);
                    bestY = float(y);
                }
            }
        }
        cellBestOut[gid.y * 4 + gid.x] = float4(bestX, bestY, bestScore, bestScore >= 16.0f ? 1.0f : 0.0f);
    }
    """

    private struct CornerGridParams {
        var width: UInt32
        var height: UInt32
        var left: UInt32
        var right: UInt32
        var top: UInt32
        var bottom: UInt32
    }

    private let lock = NSLock()
    private var outputBuffer: MTLBuffer?

    private init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        if let dev,
           let library = try? dev.makeLibrary(source: Self.mslSource, options: nil),
           let fn = library.makeFunction(name: "patchFlowCornerResponseKernel") {
            self.cornerPipeline = try? dev.makeComputePipelineState(function: fn)
            self.outputBuffer = dev.makeBuffer(length: 16 * MemoryLayout<SIMD4<Float>>.stride,
                                               options: .storageModeShared)
        } else {
            self.cornerPipeline = nil
            self.outputBuffer = nil
        }
    }

    var isAvailable: Bool {
        cornerPipeline != nil
    }

    func extractCorners(pixels: [UInt8], width: Int, height: Int,
                        left: Int, right: Int, top: Int, bottom: Int) -> [CGPoint]? {
        guard let dev = device, let queue = commandQueue, let pipeline = cornerPipeline,
              width > 8, height > 8, pixels.count == width * height else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let outBuf = outputBuffer else { return nil }
        let inBuf: MTLBuffer? = pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return dev.makeBuffer(bytes: base, length: pixels.count, options: .storageModeShared)
        }
        guard let inBuf,
              let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { return nil }

        var params = CornerGridParams(
            width: UInt32(width),
            height: UInt32(height),
            left: UInt32(left),
            right: UInt32(right),
            top: UInt32(top),
            bottom: UInt32(bottom)
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuf, offset: 0, index: 0)
        encoder.setBuffer(outBuf, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<CornerGridParams>.stride, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 1))
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status == .completed else { return nil }

        let cellPtr = outBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var points: [CGPoint] = []
        points.reserveCapacity(16)
        for i in 0..<16 {
            let v = cellPtr[i]
            if v.w > 0.5 && v.z >= 16.0 {
                points.append(CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)))
            }
        }
        return points
    }
}

/// Sparse, brightness-normalized patch correspondence inside the selected ROI.
/// It estimates motion of the selected point independently of Vision's box size.
/// All mutable state is owned by VisionFramingEngine's serial queue.
/// Upgraded with SIMD8<Float> ZNCC vectorization, zero-allocation score buffers,
/// 2D sub-pixel parabolic refinement, and Huber-weighted IRLS similarity estimation.
final class TargetPatchFlow {
    struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(buffer: CVPixelBuffer) {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let isBGRA = (format == kCVPixelFormatType_32BGRA)
            let isBiPlanarYCbCr = (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                                   format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            guard (isBGRA || isBiPlanarYCbCr),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            let inputWidth = CVPixelBufferGetWidth(buffer)
            let inputHeight = CVPixelBufferGetHeight(buffer)
            guard inputWidth > 0, inputHeight > 0 else { return nil }
            let factor = max(1.0, Double(inputWidth) / 320.0)
            let outputWidth = max(1, Int(Double(inputWidth) / factor))
            let outputHeight = max(1, Int(Double(inputHeight) / factor))
            var gray = [UInt8](repeating: 0, count: outputWidth * outputHeight)

            // Precompute horizontal source index table once outside the row loop
            // to eliminate 76,800 per-pixel floating-point divisions.
            var xLookup = [Int](repeating: 0, count: outputWidth)
            let scaleX = Double(inputWidth) / Double(outputWidth)
            let scaleY = Double(inputHeight) / Double(outputHeight)

            if isBGRA {
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for x in 0..<outputWidth {
                    let sx = min(inputWidth - 1, Int((Double(x) + 0.5) * scaleX))
                    xLookup[x] = sx * 4
                }
                gray.withUnsafeMutableBufferPointer { outPtr in
                    guard let outBase = outPtr.baseAddress else { return }
                    ntc_downsample_bgra_to_gray(
                        bytes,
                        Int32(inputWidth),
                        Int32(inputHeight),
                        Int32(rowBytes),
                        outBase,
                        Int32(outputWidth),
                        Int32(outputHeight)
                    )
                    if outBase[0] == 0 && outBase[outputWidth * outputHeight - 1] == 0 && xLookup.isEmpty {
                        xLookup.withUnsafeBufferPointer { xPtr in
                            guard let xBase = xPtr.baseAddress else { return }
                            for y in 0..<outputHeight {
                                let sourceY = min(inputHeight - 1, Int((Double(y) + 0.5) * scaleY))
                                let rowPtr = bytes.advanced(by: sourceY * rowBytes)
                                let outRowPtr = outBase.advanced(by: y * outputWidth)
                                for x in 0..<outputWidth {
                                    let offset = xBase[x]
                                    let b = Int(rowPtr[offset])
                                    let g = Int(rowPtr[offset + 1])
                                    let r = Int(rowPtr[offset + 2])
                                    outRowPtr[x] = UInt8(truncatingIfNeeded: (29 * b + 150 * g + 77 * r) >> 8)
                                }
                            }
                        }
                    }
                }
            } else {
                guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
                let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let lumaBytes = lumaBase.assumingMemoryBound(to: UInt8.self)
                for x in 0..<outputWidth {
                    xLookup[x] = min(inputWidth - 1, Int((Double(x) + 0.5) * scaleX))
                }
                gray.withUnsafeMutableBufferPointer { outPtr in
                    guard let outBase = outPtr.baseAddress else { return }
                    ntc_downsample_luma_to_gray(
                        lumaBytes,
                        Int32(inputWidth),
                        Int32(inputHeight),
                        Int32(lumaRowBytes),
                        outBase,
                        Int32(outputWidth),
                        Int32(outputHeight)
                    )
                    if outBase[0] == 0 && outBase[outputWidth * outputHeight - 1] == 0 && xLookup.isEmpty {
                        xLookup.withUnsafeBufferPointer { xPtr in
                            guard let xBase = xPtr.baseAddress else { return }
                            for y in 0..<outputHeight {
                                let sourceY = min(inputHeight - 1, Int((Double(y) + 0.5) * scaleY))
                                let rowPtr = lumaBytes.advanced(by: sourceY * lumaRowBytes)
                                let outRowPtr = outBase.advanced(by: y * outputWidth)
                                for x in 0..<outputWidth {
                                    outRowPtr[x] = rowPtr[xBase[x]]
                                }
                            }
                        }
                    }
                }
            }
            width = outputWidth; height = outputHeight; pixels = gray
        }

        @inline(__always)
        func value(_ x: Int, _ y: Int) -> Double { Double(pixels[y * width + x]) }

        @inline(__always)
        func floatValue(_ x: Int, _ y: Int) -> Float { Float(pixels[y * width + x]) }

        @inline(__always)
        func containsPatch(_ x: Int, _ y: Int) -> Bool {
            x >= 4 && y >= 4 && x < width - 4 && y < height - 4
        }

        func texturePoints(in box: CGRect) -> [CGPoint] {
            let left = max(4, Int(Double(box.minX + 0.12 * box.width) * Double(width)))
            let right = min(width - 5, Int(Double(box.maxX - 0.12 * box.width) * Double(width)))
            let top = max(4, Int(Double(1 - box.maxY + 0.12 * box.height) * Double(height)))
            let bottom = min(height - 5, Int(Double(1 - box.minY - 0.12 * box.height) * Double(height)))
            guard right > left + 8, bottom > top + 8 else { return [] }
            if (right - left) * (bottom - top) >= 4800,
               let gpuPoints = TargetPatchFlowMetalEngine.shared.extractCorners(
                   pixels: pixels, width: width, height: height,
                   left: left, right: right, top: top, bottom: bottom
               ), !gpuPoints.isEmpty {
                return gpuPoints
            }
            var cppCoords = [Float](repeating: 0, count: 32)
            let cppCount: Int32 = pixels.withUnsafeBufferPointer { pixBuf in
                cppCoords.withUnsafeMutableBufferPointer { outBuf in
                    guard let pixBase = pixBuf.baseAddress, let outBase = outBuf.baseAddress else { return 0 }
                    return ntc_extract_roi_corners(
                        pixBase,
                        Int32(width),
                        Int32(height),
                        Int32(left),
                        Int32(right),
                        Int32(top),
                        Int32(bottom),
                        outBase,
                        16
                    )
                }
            }
            if cppCount > 0 {
                var extracted: [CGPoint] = []
                extracted.reserveCapacity(Int(cppCount))
                for idx in 0..<Int(cppCount) {
                    extracted.append(CGPoint(x: CGFloat(cppCoords[idx * 2]), y: CGFloat(cppCoords[idx * 2 + 1])))
                }
                return extracted
            }
            var points: [CGPoint] = []
            points.reserveCapacity(16)
            let w = width
            pixels.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                for gy in 0..<4 {
                    for gx in 0..<4 {
                        let x0 = left + (right - left) * gx / 4
                        let x1 = left + (right - left) * (gx + 1) / 4
                        let y0 = top + (bottom - top) * gy / 4
                        let y1 = top + (bottom - top) * (gy + 1) / 4
                        var bestScore: Float = 0.0
                        var bestPoint: CGPoint?
                        for y in stride(from: y0, to: y1, by: 2) {
                            for x in stride(from: x0, to: x1, by: 2) where containsPatch(x, y) {
                                var sxx: Float = 0.0, syy: Float = 0.0, sxy: Float = 0.0
                                for v in -1...1 {
                                    let row = (y + v) * w
                                    let rowPrev = (y + v - 1) * w
                                    let rowNext = (y + v + 1) * w
                                    for u in -1...1 {
                                        let col = x + u
                                        let ix = 0.5 * (Float(base[row + col + 1]) - Float(base[row + col - 1]))
                                        let iy = 0.5 * (Float(base[rowNext + col]) - Float(base[rowPrev + col]))
                                        sxx += ix * ix
                                        syy += iy * iy
                                        sxy += ix * iy
                                    }
                                }
                                let trace = sxx + syy
                                let diff = sxx - syy
                                let disc = sqrt(max(0.0, diff * diff + 4.0 * sxy * sxy))
                                let minEigenvalue = 0.5 * (trace - disc)
                                if minEigenvalue > bestScore {
                                    bestScore = minEigenvalue
                                    bestPoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
                                }
                            }
                        }
                        if bestScore >= 16.0, let bestPoint { points.append(bestPoint) }
                    }
                }
            }
            return points
        }
    }

    struct Evaluation {
        let image: GrayImage
        let point: CGPoint
        let isReliable: Bool
        let inliers: Int
        let survivingPoints: [CGPoint]

        init(image: GrayImage, point: CGPoint, isReliable: Bool, inliers: Int, survivingPoints: [CGPoint] = []) {
            self.image = image
            self.point = point
            self.isReliable = isReliable
            self.inliers = inliers
            self.survivingPoints = survivingPoints
        }
    }

    private struct MatchedPair {
        let old: CGPoint
        let new: CGPoint
        let weight: Double
    }

    private var previous: GrayImage?
    private var points: [CGPoint] = []
    private var anchor: CGPoint?
    private var previousBox: CGRect?
    private var scratchScores: [Double] = [Double](repeating: -2.0, count: 32 * 32)

    func reset() {
        previous = nil; points = []; anchor = nil; previousBox = nil
    }

    func seed(buffer: CVPixelBuffer, box: CGRect, point: CGPoint) {
        reset()
        guard let image = GrayImage(buffer: buffer) else { return }
        previous = image
        points = image.texturePoints(in: box)
        anchor = point
        previousBox = box
    }

    func evaluate(buffer: CVPixelBuffer, box: CGRect, fallback: CGPoint, gyroNormalizedShift: CGPoint = .zero) -> Evaluation? {
        guard let image = GrayImage(buffer: buffer) else { return nil }
        guard let previous, previous.width == image.width, previous.height == image.height,
              let anchor, let previousBox, points.count >= 5 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: 0)
        }
        let visionDx = Double(box.midX - previousBox.midX) * Double(image.width)
        let visionDy = Double(previousBox.midY - box.midY) * Double(image.height)
        let coarseX: Double
        let coarseY: Double
        if gyroNormalizedShift != .zero,
           gyroNormalizedShift.x.isFinite, gyroNormalizedShift.y.isFinite {
            let gyroDx = Double(gyroNormalizedShift.x) * Double(image.width)
            let gyroDy = Double(gyroNormalizedShift.y) * Double(image.height)
            if visionDx.isFinite, visionDy.isFinite {
                let diff = hypot(visionDx - gyroDx, visionDy - gyroDy)
                let gyroSpeed = hypot(gyroDx, gyroDy)
                // When camera rotates quickly (gyroSpeed >= 8.0) and vision lags behind (diff > 15.0),
                // gyro provides the superior coarse motion estimate.
                // However, during translation or walking, gyro is small (~0) while vision observes
                // real parallax displacement. In that case, vision must lead coarse centering.
                if gyroSpeed >= 8.0 && diff > 15.0 {
                    coarseX = gyroDx
                    coarseY = gyroDy
                } else if hypot(visionDx, visionDy) <= 80.0 {
                    coarseX = visionDx
                    coarseY = visionDy
                } else {
                    coarseX = gyroDx
                    coarseY = gyroDy
                }
            } else {
                coarseX = gyroDx
                coarseY = gyroDy
            }
        } else if visionDx.isFinite, visionDy.isFinite, hypot(visionDx, visionDy) <= 80.0 {
            coarseX = visionDx
            coarseY = visionDy
        } else {
            coarseX = 0.0
            coarseY = 0.0
        }

        // Fast-path C++17 / ARM NEON 3-Level Pyramidal IC-LK + 256-bit ORB + Huber IRLS Constellation Solver
        var flatPrevPoints = [Float](repeating: 0, count: points.count * 2)
        for (idx, pt) in points.enumerated() {
            flatPrevPoints[idx * 2] = Float(pt.x)
            flatPrevPoints[idx * 2 + 1] = Float(pt.y)
        }
        var flatSurvivors = [Float](repeating: 0, count: points.count * 2)
        let ntcEval: NTCPatchFlowResult = previous.pixels.withUnsafeBufferPointer { prevBuf in
            image.pixels.withUnsafeBufferPointer { currBuf in
                flatPrevPoints.withUnsafeBufferPointer { ptsBuf in
                    flatSurvivors.withUnsafeMutableBufferPointer { survBuf in
                        guard let prevBase = prevBuf.baseAddress,
                              let currBase = currBuf.baseAddress,
                              let ptsBase = ptsBuf.baseAddress,
                              let survBase = survBuf.baseAddress else {
                            return NTCPatchFlowResult(anchorNormX: Double(fallback.x),
                                                      anchorNormY: Double(fallback.y),
                                                      inliers: 0,
                                                      survivingCount: 0,
                                                      isReliable: false)
                        }
                        return ntc_evaluate_constellation_flow(
                            prevBase,
                            currBase,
                            Int32(image.width),
                            Int32(image.height),
                            ptsBase,
                            Int32(points.count),
                            coarseX,
                            coarseY,
                            Double(previousBox.width),
                            Double(box.width),
                            Double(box.minX),
                            Double(box.minY),
                            Double(box.maxX),
                            Double(box.maxY),
                            Double(anchor.x),
                            Double(anchor.y),
                            survBase,
                            Int32(points.count)
                        )
                    }
                }
            }
        }
        if ntcEval.isReliable {
            var survivors: [CGPoint] = []
            let survCount = Int(max(0, ntcEval.survivingCount))
            survivors.reserveCapacity(survCount)
            for idx in 0..<survCount {
                survivors.append(CGPoint(x: CGFloat(flatSurvivors[idx * 2]),
                                         y: CGFloat(flatSurvivors[idx * 2 + 1])))
            }
            return Evaluation(
                image: image,
                point: CGPoint(x: ntcEval.anchorNormX, y: ntcEval.anchorNormY),
                isReliable: true,
                inliers: Int(ntcEval.inliers),
                survivingPoints: survivors
            )
        }

        var pairs: [MatchedPair] = []
        pairs.reserveCapacity(points.count)
        for old in points {
            let targetX = Double(old.x) + coarseX
            let targetY = Double(old.y) + coarseY
            guard targetX.isFinite, targetY.isFinite else { continue }
            // Clamp search center within image bounds so the +/-10 search window
            // never collapses at image margins or causes integer overflow/underflow.
            let clampedCenterX = max(4.0, min(Double(image.width - 5), targetX))
            let clampedCenterY = max(4.0, min(Double(image.height - 5), targetY))
            let center = CGPoint(x: clampedCenterX, y: clampedCenterY)
            guard let (new, fwdScore) = matchWithScore(template: previous, at: old, in: image,
                                                       around: center, radius: 10, requireUnique: true),
                  let (reverse, _) = matchWithScore(template: image, at: new, in: previous,
                                                    around: old, radius: 4, requireUnique: false) else { continue }
            let fbError = hypot(reverse.x - old.x, reverse.y - old.y)
            guard fbError <= 1.5 else { continue }
            let qualityWeight = max(0.25, min(1.0, (fwdScore - 0.75) / 0.25)) * max(0.35, 1.0 - Double(fbError) / 2.0)
            pairs.append(MatchedPair(old: old, new: new, weight: qualityWeight))
        }
        guard pairs.count >= 5 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: pairs.count)
        }
        let dx = median(pairs.map { Double($0.new.x - $0.old.x) })
        let dy = median(pairs.map { Double($0.new.y - $0.old.y) })
        let scaleRatio = (previousBox.width > 0.001 && box.width > 0.001) ?
            Double(box.width / previousBox.width) : 1.0
        let clampedScale = max(0.80, min(1.25, scaleRatio))
        let cOldX = pairs.reduce(0.0) { $0 + Double($1.old.x) } / Double(pairs.count)
        let cOldY = pairs.reduce(0.0) { $0 + Double($1.old.y) } / Double(pairs.count)
        let inliers = pairs.filter { pair in
            let expectedDx = dx + (clampedScale - 1.0) * (Double(pair.old.x) - cOldX)
            let expectedDy = dy + (clampedScale - 1.0) * (Double(pair.old.y) - cOldY)
            let residual = hypot(Double(pair.new.x - pair.old.x) - expectedDx,
                                 Double(pair.new.y - pair.old.y) - expectedDy)
            return residual <= 2.6
        }
        guard inliers.count >= 5 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: inliers.count)
        }

        // 2-Pass Iteratively Reweighted Least Squares (IRLS with Huber weights)
        // for 4-DOF similarity transform (a, b, tx, ty) with gentle scale/rotation regularization.
        var weights = inliers.map(\.weight)
        var oldX = 0.0, oldY = 0.0, newX = 0.0, newY = 0.0
        var a = 1.0, b = 0.0

        for pass in 0..<2 {
            let wSum = max(1e-9, weights.reduce(0.0, +))
            oldX = zip(inliers, weights).reduce(0.0) { $0 + Double($1.0.old.x) * $1.1 } / wSum
            oldY = zip(inliers, weights).reduce(0.0) { $0 + Double($1.0.old.y) * $1.1 } / wSum
            newX = zip(inliers, weights).reduce(0.0) { $0 + Double($1.0.new.x) * $1.1 } / wSum
            newY = zip(inliers, weights).reduce(0.0) { $0 + Double($1.0.new.y) * $1.1 } / wSum

            var denominator = 0.0, numeratorA = 0.0, numeratorB = 0.0
            for (idx, pair) in inliers.enumerated() {
                let w = weights[idx]
                let x = Double(pair.old.x) - oldX, y = Double(pair.old.y) - oldY
                let u = Double(pair.new.x) - newX, v = Double(pair.new.y) - newY
                denominator += w * (x * x + y * y)
                numeratorA += w * (x * u + y * v)
                numeratorB += w * (x * v - y * u)
            }
            // Bayesian prior toward pure translation (a=1, b=0) when point constellation spread is small
            let priorWeight = 8.0
            a = denominator > 1.0 ? (numeratorA + priorWeight) / (denominator + priorWeight) : 1.0
            b = denominator > 1.0 ? numeratorB / (denominator + priorWeight) : 0.0

            if pass == 0 {
                let huberDelta = 1.25
                for (idx, pair) in inliers.enumerated() {
                    let x = Double(pair.old.x) - oldX, y = Double(pair.old.y) - oldY
                    let predU = a * x - b * y
                    let predV = b * x + a * y
                    let u = Double(pair.new.x) - newX, v = Double(pair.new.y) - newY
                    let err = hypot(u - predU, v - predV)
                    let huber = err <= huberDelta ? 1.0 : (huberDelta / err)
                    weights[idx] = pair.weight * huber
                }
            }
        }

        let scale = hypot(a, b)
        guard (0.75...1.35).contains(scale) else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: inliers.count)
        }
        let oldAnchorX = Double(anchor.x) * Double(image.width) - oldX
        let oldAnchorY = Double(anchor.y) * Double(image.height) - oldY
        let result = CGPoint(x: (newX + a * oldAnchorX - b * oldAnchorY) / Double(image.width),
                             y: (newY + b * oldAnchorX + a * oldAnchorY) / Double(image.height))
        let expanded = box.insetBy(dx: -0.04, dy: -0.04)
        let visionResult = CGPoint(x: result.x, y: 1 - result.y)
        guard result.x.isFinite, result.y.isFinite, expanded.contains(visionResult),
              (0...1).contains(result.x), (0...1).contains(result.y) else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: inliers.count)
        }
        return Evaluation(image: image, point: result, isReliable: true, inliers: inliers.count,
                          survivingPoints: inliers.map(\.new))
    }

    func accept(_ evaluation: Evaluation, box: CGRect, point: CGPoint) {
        previous = evaluation.image
        let freshPoints = evaluation.image.texturePoints(in: box)
        if freshPoints.count >= 10 {
            points = freshPoints
        } else {
            // Merge high-confidence surviving landmarks with fresh Shi-Tomasi corners
            // so motion-blurred frames during handheld pans do not starve the constellation.
            var merged = freshPoints
            let w = Double(evaluation.image.width)
            let h = Double(evaluation.image.height)
            let left = Double(box.minX + 0.08 * box.width) * w
            let right = Double(box.maxX - 0.08 * box.width) * w
            let top = Double(1 - box.maxY + 0.08 * box.height) * h
            let bottom = Double(1 - box.minY - 0.08 * box.height) * h
            for survivor in evaluation.survivingPoints {
                guard merged.count < 16 else { break }
                let sx = Double(survivor.x), sy = Double(survivor.y)
                guard sx >= left, sx <= right, sy >= top, sy <= bottom,
                      evaluation.image.containsPatch(Int(sx.rounded()), Int(sy.rounded())) else { continue }
                let tooClose = merged.contains { hypot($0.x - survivor.x, $0.y - survivor.y) < 4.5 }
                if !tooClose {
                    merged.append(survivor)
                }
            }
            points = merged
        }
        anchor = point
        previousBox = box
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func match(template: GrayImage, at source: CGPoint, in target: GrayImage,
                       around center: CGPoint, radius: Int, requireUnique: Bool) -> CGPoint? {
        matchWithScore(template: template, at: source, in: target,
                       around: center, radius: radius, requireUnique: requireUnique)?.0
    }

    private func matchWithScore(template: GrayImage, at source: CGPoint, in target: GrayImage,
                                around center: CGPoint, radius: Int, requireUnique: Bool) -> (CGPoint, Double)? {
        guard source.x.isFinite, source.y.isFinite, center.x.isFinite, center.y.isFinite else { return nil }
        let sx = Int(source.x.rounded()), sy = Int(source.y.rounded())
        guard template.containsPatch(sx, sy) else { return nil }
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let minX = max(4, min(target.width - 5, cx - radius))
        let maxX = min(target.width - 5, max(4, cx + radius))
        let minY = max(4, min(target.height - 5, cy - radius))
        let maxY = min(target.height - 5, max(4, cy + radius))
        guard minX <= maxX, minY <= maxY else { return nil }

        let spanX = maxX - minX + 1
        let spanY = maxY - minY + 1
        let gridCount = spanX * spanY
        if scratchScores.count < gridCount {
            scratchScores = [Double](repeating: -2.0, count: max(gridCount, 32 * 32))
        }

        return template.pixels.withUnsafeBufferPointer { tplBuf -> (CGPoint, Double)? in
            target.pixels.withUnsafeBufferPointer { tgtBuf -> (CGPoint, Double)? in
                guard let tplBase = tplBuf.baseAddress, let tgtBase = tgtBuf.baseAddress else { return nil }
                var cppBestX: Float = 0.0
                var cppBestY: Float = 0.0
                var cppBestScore: Double = -2.0
                if ntc_match_patch_zncc(
                    tplBase,
                    Int32(template.width),
                    Int32(template.height),
                    Float(source.x),
                    Float(source.y),
                    tgtBase,
                    Int32(target.width),
                    Int32(target.height),
                    Float(center.x),
                    Float(center.y),
                    Int32(radius),
                    requireUnique,
                    &cppBestX,
                    &cppBestY,
                    &cppBestScore
                ) {
                    return (CGPoint(x: CGFloat(cppBestX), y: CGFloat(cppBestY)), cppBestScore)
                }
                let tplW = template.width
                let tgtW = target.width

                // Extract 7x7 template patch (49 pixels = 6 x SIMD8<Float> + 1 Float) once
                var aFlat = [Float](repeating: 0, count: 49)
                var idx = 0
                var sumA: Double = 0.0
                var sumAA: Double = 0.0
                for offsetY in -3...3 {
                    let rowOffset = (sy + offsetY) * tplW + sx
                    for offsetX in -3...3 {
                        let v = Double(tplBase[rowOffset + offsetX])
                        aFlat[idx] = Float(v)
                        idx += 1
                        sumA += v
                        sumAA += v * v
                    }
                }
                let varA = 49.0 * sumAA - sumA * sumA
                guard varA > 10.0 else { return nil }

                let aVec0 = SIMD8<Float>(aFlat[0], aFlat[1], aFlat[2], aFlat[3], aFlat[4], aFlat[5], aFlat[6], aFlat[7])
                let aVec1 = SIMD8<Float>(aFlat[8], aFlat[9], aFlat[10], aFlat[11], aFlat[12], aFlat[13], aFlat[14], aFlat[15])
                let aVec2 = SIMD8<Float>(aFlat[16], aFlat[17], aFlat[18], aFlat[19], aFlat[20], aFlat[21], aFlat[22], aFlat[23])
                let aVec3 = SIMD8<Float>(aFlat[24], aFlat[25], aFlat[26], aFlat[27], aFlat[28], aFlat[29], aFlat[30], aFlat[31])
                let aVec4 = SIMD8<Float>(aFlat[32], aFlat[33], aFlat[34], aFlat[35], aFlat[36], aFlat[37], aFlat[38], aFlat[39])
                let aVec5 = SIMD8<Float>(aFlat[40], aFlat[41], aFlat[42], aFlat[43], aFlat[44], aFlat[45], aFlat[46], aFlat[47])
                let aLast = aFlat[48]

                var bestScore = -Double.infinity
                var bestX = minX
                var bestY = minY

                for y in minY...maxY {
                    let gridRowOffset = (y - minY) * spanX
                    let r0 = (y - 3) * tgtW
                    let r1 = (y - 2) * tgtW
                    let r2 = (y - 1) * tgtW
                    let r3 = y * tgtW
                    let r4 = (y + 1) * tgtW
                    let r5 = (y + 2) * tgtW
                    let r6 = (y + 3) * tgtW

                    for x in minX...maxX {
                        let gridIndex = gridRowOffset + (x - minX)
                        guard target.containsPatch(x, y) else {
                            scratchScores[gridIndex] = -2.0
                            continue
                        }
                        let c = x - 3
                        let bVec0 = SIMD8<Float>(
                            Float(tgtBase[r0 + c]), Float(tgtBase[r0 + c + 1]), Float(tgtBase[r0 + c + 2]), Float(tgtBase[r0 + c + 3]),
                            Float(tgtBase[r0 + c + 4]), Float(tgtBase[r0 + c + 5]), Float(tgtBase[r0 + c + 6]), Float(tgtBase[r1 + c])
                        )
                        let bVec1 = SIMD8<Float>(
                            Float(tgtBase[r1 + c + 1]), Float(tgtBase[r1 + c + 2]), Float(tgtBase[r1 + c + 3]), Float(tgtBase[r1 + c + 4]),
                            Float(tgtBase[r1 + c + 5]), Float(tgtBase[r1 + c + 6]), Float(tgtBase[r2 + c]), Float(tgtBase[r2 + c + 1])
                        )
                        let bVec2 = SIMD8<Float>(
                            Float(tgtBase[r2 + c + 2]), Float(tgtBase[r2 + c + 3]), Float(tgtBase[r2 + c + 4]), Float(tgtBase[r2 + c + 5]),
                            Float(tgtBase[r2 + c + 6]), Float(tgtBase[r3 + c]), Float(tgtBase[r3 + c + 1]), Float(tgtBase[r3 + c + 2])
                        )
                        let bVec3 = SIMD8<Float>(
                            Float(tgtBase[r3 + c + 3]), Float(tgtBase[r3 + c + 4]), Float(tgtBase[r3 + c + 5]), Float(tgtBase[r3 + c + 6]),
                            Float(tgtBase[r4 + c]), Float(tgtBase[r4 + c + 1]), Float(tgtBase[r4 + c + 2]), Float(tgtBase[r4 + c + 3])
                        )
                        let bVec4 = SIMD8<Float>(
                            Float(tgtBase[r4 + c + 4]), Float(tgtBase[r4 + c + 5]), Float(tgtBase[r4 + c + 6]), Float(tgtBase[r5 + c]),
                            Float(tgtBase[r5 + c + 1]), Float(tgtBase[r5 + c + 2]), Float(tgtBase[r5 + c + 3]), Float(tgtBase[r5 + c + 4])
                        )
                        let bVec5 = SIMD8<Float>(
                            Float(tgtBase[r5 + c + 5]), Float(tgtBase[r5 + c + 6]), Float(tgtBase[r6 + c]), Float(tgtBase[r6 + c + 1]),
                            Float(tgtBase[r6 + c + 2]), Float(tgtBase[r6 + c + 3]), Float(tgtBase[r6 + c + 4]), Float(tgtBase[r6 + c + 5])
                        )
                        let bLast = Float(tgtBase[r6 + c + 6])

                        let sumBVec = bVec0 + bVec1 + bVec2 + bVec3 + bVec4 + bVec5
                        let sumB = Double(sumBVec.sum() + bLast)
                        let sumBBVec = bVec0 * bVec0 + bVec1 * bVec1 + bVec2 * bVec2 + bVec3 * bVec3 + bVec4 * bVec4 + bVec5 * bVec5
                        let sumBB = Double(sumBBVec.sum() + bLast * bLast)
                        let sumABVec = aVec0 * bVec0 + aVec1 * bVec1 + aVec2 * bVec2 + aVec3 * bVec3 + aVec4 * bVec4 + aVec5 * bVec5
                        let sumAB = Double(sumABVec.sum() + aLast * bLast)

                        let varB = 49.0 * sumBB - sumB * sumB
                        let variance = varA * varB
                        if variance > 100.0 {
                            let score = (49.0 * sumAB - sumA * sumB) / sqrt(variance)
                            scratchScores[gridIndex] = score
                            if score > bestScore {
                                bestScore = score
                                bestX = x
                                bestY = y
                            }
                        } else {
                            scratchScores[gridIndex] = -2.0
                        }
                    }
                }

                guard bestScore >= 0.78 else { return nil }

                if requireUnique {
                    var bestRival = -Double.infinity
                    for y in minY...maxY {
                        let gridRowOffset = (y - minY) * spanX
                        for x in minX...maxX {
                            if abs(x - bestX) > 2 || abs(y - bestY) > 2 {
                                let s = scratchScores[gridRowOffset + (x - minX)]
                                if s > bestRival {
                                    bestRival = s
                                }
                            }
                        }
                    }
                    if bestRival.isFinite && bestScore - bestRival < 0.035 {
                        return nil
                    }
                }

                // 2D Sub-Pixel Parabolic Refinement around (bestX, bestY)
                var subX = Double(bestX)
                var subY = Double(bestY)
                if bestX > minX && bestX < maxX {
                    let rowOff = (bestY - minY) * spanX
                    let sLeft = scratchScores[rowOff + (bestX - 1 - minX)]
                    let sRight = scratchScores[rowOff + (bestX + 1 - minX)]
                    if sLeft > -1.0 && sRight > -1.0 {
                        let denom = 2.0 * (sLeft - 2.0 * bestScore + sRight)
                        if abs(denom) > 1e-6 && denom < 0 {
                            let deltaX = (sLeft - sRight) / denom
                            subX += max(-0.45, min(0.45, deltaX))
                        }
                    }
                }
                if bestY > minY && bestY < maxY {
                    let colOff = bestX - minX
                    let sUp = scratchScores[(bestY - 1 - minY) * spanX + colOff]
                    let sDown = scratchScores[(bestY + 1 - minY) * spanX + colOff]
                    if sUp > -1.0 && sDown > -1.0 {
                        let denom = 2.0 * (sUp - 2.0 * bestScore + sDown)
                        if abs(denom) > 1e-6 && denom < 0 {
                            let deltaY = (sUp - sDown) / denom
                            subY += max(-0.45, min(0.45, deltaY))
                        }
                    }
                }

                return (CGPoint(x: CGFloat(subX), y: CGFloat(subY)), bestScore)
            }
        }
    }
}
