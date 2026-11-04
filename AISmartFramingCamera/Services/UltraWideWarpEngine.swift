//
//  UltraWideWarpEngine.swift
//  AISmartFramingCamera
//
//  Created by AlignAI Studio on 2026-11-04.
//  Zero-Copy GPU Simulated Ultra-Wide 0.5x Canvas Zoom-Out Engine (Metal Compute).
//

import Foundation
import CoreImage
import CoreGraphics
import CoreVideo
import Metal
import UIKit

/// Động cơ Giả lập Quang học Góc Siêu rộng (Simulated Ultra-Wide 0.5x Engine)
/// Hỗ trợ kiến trúc Zero-Copy, không chặn GPU (non-blocking), texture pooling và canvas zoom-out.
public final class UltraWideWarpEngine: @unchecked Sendable {

    // MARK: - Chế độ hoạt động & Rollback
    /// Chuyển đổi giữa Canvas Zoom-Out mới (true) và SuperView Anamorphic cũ (false) để rollback an toàn.
    public static var useCanvasMode: Bool = true

    // MARK: - Singleton Instances (Live & Photo tách biệt pool)
    public static let live = UltraWideWarpEngine(maxOutputWidth: 1920)
    public static let photo = UltraWideWarpEngine(maxOutputWidth: Int.max)
    public static var shared: UltraWideWarpEngine { live }

    // MARK: - Metal & CoreVideo Resources
    public var maxOutputWidth: Int
    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    public let ciContext: CIContext
    private let canvasPipeline: MTLComputePipelineState?
    private let legacyPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private let poolLock = NSLock()

    // Giới hạn số khung hình đang xử lý đồng thời trên GPU
    private let frameSemaphore: DispatchSemaphore
    private let isPhotoEngine: Bool
    private var lastOutputCI: CIImage?
    private let stateLock = NSLock()

    // Cấu trúc tham số cho Metal Shader Canvas Zoom-Out
    private struct WideParams {
        var scale: Float     // = factor, từ 0.5 đến 1.0
        var blur: Float      // 0.10
        var vignette: Float  // 0.25
    }

    // Cấu trúc tham số cho Metal Shader SuperView cũ
    private struct SuperViewParams {
        var beta_x: Float
        var beta_y: Float
    }

    /// Kiểm tra phần cứng có hỗ trợ Metal Shader này không
    public var isSupported: Bool {
        return device != nil && (Self.useCanvasMode ? canvasPipeline != nil : legacyPipeline != nil)
    }

    // MARK: - Initialization
    public init(maxOutputWidth: Int) {
        self.maxOutputWidth = maxOutputWidth
        let isPhoto = maxOutputWidth > 4000
        self.isPhotoEngine = isPhoto
        self.frameSemaphore = isPhoto ? DispatchSemaphore(value: 1) : DispatchSemaphore(value: 3)

        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        let queue = dev?.makeCommandQueue()
        self.commandQueue = queue

        if let dev = dev, let queue = queue {
            // CIContext chia sẻ chung MTLCommandQueue để đảm bảo thứ tự thực thi GPU
            self.ciContext = CIContext(mtlCommandQueue: queue, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])

            // Khởi tạo CVMetalTextureCache
            var cache: CVMetalTextureCache?
            let cvReturn = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            if cvReturn == kCVReturnSuccess {
                self.textureCache = cache
            }

            // Tải Metal Shader Library
            var canvasState: MTLComputePipelineState?
            var legacyState: MTLComputePipelineState?
            let defaultLib = dev.makeDefaultLibrary() ?? (try? dev.makeDefaultLibrary(bundle: Bundle.main))
            if let lib = defaultLib {
                if let canvasFn = lib.makeFunction(name: "ultraWideCanvasKernel") {
                    canvasState = try? dev.makeComputePipelineState(function: canvasFn)
                }
                if let legacyFn = lib.makeFunction(name: "separableSuperViewKernel") {
                    legacyState = try? dev.makeComputePipelineState(function: legacyFn)
                }
            }
            self.canvasPipeline = canvasState
            self.legacyPipeline = legacyState
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
            self.canvasPipeline = nil
            self.legacyPipeline = nil
        }

        // Lắng nghe trạng thái nhiệt độ thiết bị để giảm tải khi máy quá nóng
        if !isPhoto {
            setupThermalObservation()
        }
    }

    private func setupThermalObservation() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isPhotoEngine else { return }
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                self.maxOutputWidth = 1280
            } else if state == .nominal || state == .fair {
                self.maxOutputWidth = 1920
            }
        }
    }

    // MARK: - CVPixelBufferPool Management
    private func getOrCreatePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        poolLock.lock()
        defer { poolLock.unlock() }

        if let pool = pixelBufferPool, poolWidth == width, poolHeight == height {
            return pool
        }

        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pbAttrs as CFDictionary,
            &newPool
        )

        if status == kCVReturnSuccess, let createdPool = newPool {
            self.pixelBufferPool = createdPool
            self.poolWidth = width
            self.poolHeight = height
            return createdPool
        }
        return nil
    }

    // MARK: - Texture Mapping (Zero-Copy từ CVPixelBuffer)
    private func makeTexture(from pb: CVPixelBuffer) -> (tex: MTLTexture, cv: CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        guard st == kCVReturnSuccess, let cv = cvTex, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

    // MARK: - Core GPU Encoding (Non-blocking, không chờ GPU)
    private func encode(
        src: CVPixelBuffer,
        dst: CVPixelBuffer,
        scale: Float,
        completion: @escaping () -> Void
    ) -> Bool {
        guard let inT = makeTexture(from: src),
              let outT = makeTexture(from: dst),
              let cmd = commandQueue?.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return false
        }

        if Self.useCanvasMode, let pipeline = canvasPipeline {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(inT.tex, index: 0)
            enc.setTexture(outT.tex, index: 1)
            var params = WideParams(scale: scale, blur: 0.10, vignette: 0.25)
            enc.setBytes(&params, length: MemoryLayout<WideParams>.stride, index: 0)

            let tw = pipeline.threadExecutionWidth
            let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
            let tg = MTLSize(width: tw, height: th, depth: 1)
            let grid = MTLSize(width: outT.tex.width, height: outT.tex.height, depth: 1)

            if let dev = device, dev.supportsFamily(.apple4) {
                enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            } else {
                let groups = MTLSize(width: (grid.width + tw - 1) / tw, height: (grid.height + th - 1) / th, depth: 1)
                enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            }
        } else if let pipeline = legacyPipeline {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(inT.tex, index: 0)
            enc.setTexture(outT.tex, index: 1)
            let progress = Float(min(max((1.0 - scale) / 0.5, 0.0), 1.0))
            var params = SuperViewParams(beta_x: 0.20 * progress, beta_y: 0.14 * progress)
            enc.setBytes(&params, length: MemoryLayout<SuperViewParams>.stride, index: 0)

            let tw = pipeline.threadExecutionWidth
            let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
            let tg = MTLSize(width: tw, height: th, depth: 1)
            let groups = MTLSize(width: (outT.tex.width + tw - 1) / tw, height: (outT.tex.height + th - 1) / th, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        } else {
            enc.endEncoding()
            return false
        }

        enc.endEncoding()
        cmd.addCompletedHandler { _ in
            _ = inT.cv
            _ = outT.cv
            completion()
        }
        cmd.commit()
        return true
    }

    // MARK: - Process Direct PixelBuffer (Dành cho Video Recording)
    public func processToPixelBuffer(
        _ src: CVPixelBuffer,
        factor: CGFloat,
        completion: @escaping (CVPixelBuffer) -> Void
    ) {
        if factor >= 0.999 || !isSupported {
            completion(src)
            return
        }

        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let targetW = max(2, min(srcW, maxOutputWidth) & ~1)
        let targetH = max(2, (targetW * srcH / srcW) & ~1)

        guard let pool = getOrCreatePixelBufferPool(width: targetW, height: targetH) else {
            completion(src)
            return
        }

        let auxAttrs: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: 6
        ]
        var outBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttrs as CFDictionary,
            &outBuffer
        )
        guard status == kCVReturnSuccess, let dst = outBuffer else {
            completion(src)
            return
        }

        if !isPhotoEngine {
            let waitResult = frameSemaphore.wait(timeout: .now())
            if waitResult == .timedOut {
                completion(src)
                return
            }
        } else {
            frameSemaphore.wait()
        }

        let ok = encode(src: src, dst: dst, scale: Float(factor)) { [weak self] in
            self?.frameSemaphore.signal()
            completion(dst)
        }
        if !ok {
            frameSemaphore.signal()
            completion(src)
        }
    }

    // MARK: - Public API: CIImage (Live Viewfinder & Video Compositor)
    public func applySimulatedUltraWide(
        to image: CIImage,
        factor: CGFloat = 0.5,
        horizonRollAngle: Float = 0.0,
        horizonZoomScale: Float = 1.0,
        horizonShakeX: Float = 0.0,
        horizonShakeY: Float = 0.0
    ) -> CIImage {
        guard factor < 0.999, isSupported else { return image }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        let srcW = Int(extent.width)
        let srcH = Int(extent.height)
        let targetW = max(2, min(srcW, maxOutputWidth) & ~1)
        let targetH = max(2, (targetW * srcH / srcW) & ~1)

        if !isPhotoEngine {
            let waitResult = frameSemaphore.wait(timeout: .now())
            if waitResult == .timedOut {
                stateLock.lock()
                let fallback = lastOutputCI ?? image
                stateLock.unlock()
                return fallback
            }
        } else {
            frameSemaphore.wait()
        }

        guard let pool = getOrCreatePixelBufferPool(width: targetW, height: targetH) else {
            frameSemaphore.signal()
            return image
        }

        let srcBuffer: CVPixelBuffer
        var tempSrcBuffer: CVPixelBuffer? = nil
        if let pb = image.pixelBuffer,
           CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetWidth(pb) == targetW,
           CVPixelBufferGetHeight(pb) == targetH {
            srcBuffer = pb
        } else {
            var inPB: CVPixelBuffer?
            let auxAttrs: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 6]
            let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttrs as CFDictionary, &inPB)
            guard st == kCVReturnSuccess, let allocatedIn = inPB else {
                frameSemaphore.signal()
                stateLock.lock()
                let fallback = lastOutputCI ?? image
                stateLock.unlock()
                return fallback
            }
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            ciContext.render(image, to: allocatedIn, bounds: extent, colorSpace: colorSpace)
            srcBuffer = allocatedIn
            tempSrcBuffer = allocatedIn
        }

        var dstBuffer: CVPixelBuffer?
        let auxAttrs: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 6]
        let stOut = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttrs as CFDictionary, &dstBuffer)
        guard stOut == kCVReturnSuccess, let outPB = dstBuffer else {
            _ = tempSrcBuffer
            frameSemaphore.signal()
            stateLock.lock()
            let fallback = lastOutputCI ?? image
            stateLock.unlock()
            return fallback
        }

        let ok = encode(src: srcBuffer, dst: outPB, scale: Float(factor)) { [weak self] in
            _ = tempSrcBuffer
            self?.frameSemaphore.signal()
        }

        if !ok {
            frameSemaphore.signal()
            return image
        }

        let outCI = CIImage(cvPixelBuffer: outPB)
        stateLock.lock()
        lastOutputCI = outCI
        stateLock.unlock()
        return outCI
    }

    // MARK: - Public API: CGImage (Chụp ảnh tĩnh Photo Capture)
    public func applySimulatedUltraWide(
        to cgImage: CGImage,
        factor: CGFloat = 0.5,
        horizonRollAngle: Float = 0.0,
        horizonZoomScale: Float = 1.0,
        horizonShakeX: Float = 0.0,
        horizonShakeY: Float = 0.0
    ) -> CGImage? {
        if !isPhotoEngine {
            return UltraWideWarpEngine.photo.applySimulatedUltraWide(
                to: cgImage,
                factor: factor,
                horizonRollAngle: horizonRollAngle,
                horizonZoomScale: horizonZoomScale,
                horizonShakeX: horizonShakeX,
                horizonShakeY: horizonShakeY
            )
        }

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var ciImage = CIImage(cgImage: cgImage, options: [.colorSpace: colorSpace])
        let extent = ciImage.extent

        if abs(horizonRollAngle) > 0.0005 || horizonZoomScale > 1.001 {
            let roll = CGFloat(-horizonRollAngle)
            let zoom = CGFloat(horizonZoomScale)
            let shakeX = CGFloat(horizonShakeX) * extent.width
            let shakeY = CGFloat(horizonShakeY) * extent.height
            let t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(rotationAngle: roll))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: extent.midX + shakeX, y: extent.midY + shakeY))
            let bgBlack = CIImage(color: .black).cropped(to: extent)
            ciImage = ciImage.transformed(by: t).composited(over: bgBlack).cropped(to: extent)
        }

        guard factor < 0.999, isSupported else {
            return ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace)
        }

        let width = Int(extent.width) & ~1
        let height = Int(extent.height) & ~1
        guard let pool = getOrCreatePixelBufferPool(width: width, height: height) else {
            return ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace)
        }

        var inPB: CVPixelBuffer?
        var outPB: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &inPB)
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPB)

        guard let inBuf = inPB, let outBuf = outPB else {
            return ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace)
        }

        ciContext.render(ciImage, to: inBuf, bounds: extent, colorSpace: colorSpace)

        let photoDone = DispatchSemaphore(value: 0)
        let ok = encode(src: inBuf, dst: outBuf, scale: Float(factor)) {
            photoDone.signal()
        }

        if ok {
            photoDone.wait()
            let warpedCI = CIImage(cvPixelBuffer: outBuf)
            return ciContext.createCGImage(warpedCI, from: warpedCI.extent, format: .RGBA8, colorSpace: colorSpace)
        } else {
            return ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace)
        }
    }
}
