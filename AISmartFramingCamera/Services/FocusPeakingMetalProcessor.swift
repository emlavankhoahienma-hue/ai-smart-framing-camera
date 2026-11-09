//
//  FocusPeakingMetalProcessor.swift
//  AISmartFramingCamera
//
//  Cinematic GPU Focus Peaking Processor (Metal Compute Architecture)
//  Algorithms:
//  - Zero-Copy CVMetalTextureCache Ingestion
//  - Rec.709 Luma + Box Downsample to Display-Matched Work Resolution
//  - Fused Threadgroup Tile Denoise + Dual-Scale Scharr + Re-Blur Defocus Ratio
//  - Dynamic Noise Floor Adaptation based on Sensor ISO
//  - Highlight (>=250) and Crushed Shadow (<=4) Artifact Rejection
//  - 64-bin Parallel GPU Histogram + CDF Percentile + Temporal EMA Threshold (Zero CPU Readback)
//  - Directional Non-Maximum Suppression (1px thin ridges) + Hysteresis + Isolated Despeckle Filter
//  - Temporal Ping-Pong Accumulation (Instant Attack, Smooth Decay)
//  - Antialiased Constant-Thickness (~1.5pt) On-Screen Overlay Composition
//

import Foundation
import CoreVideo
import CoreImage
import Metal
import simd

public final class FocusPeakingMetalProcessor: @unchecked Sendable {
    public static let shared = FocusPeakingMetalProcessor()

    // MARK: - Metal Device & Queues
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    // MARK: - Compute Pipeline States
    private var downscaleLumaPipeline: MTLComputePipelineState?
    private var fusedScharrPipeline: MTLComputePipelineState?
    private var histogramPipeline: MTLComputePipelineState?
    private var adaptiveThresholdPipeline: MTLComputePipelineState?
    private var thinningPipeline: MTLComputePipelineState?
    private var temporalPipeline: MTLComputePipelineState?
    private var compositePipeline: MTLComputePipelineState?

    // MARK: - GPU Intermediate Textures (Private GPU Storage)
    private var lumaWorkTexture: MTLTexture?
    private var sharpnessTexture: MTLTexture?
    private var candidateMaskTexture: MTLTexture?
    private var pingPongTextures: [MTLTexture?] = [nil, nil]
    private var currentPingPongIndex: Int = 0

    private var currentWorkWidth: Int = 0
    private var currentWorkHeight: Int = 0

    // MARK: - GPU Buffers (Zero CPU Readback)
    private var histogramBuffer: MTLBuffer?
    private var activePixelCountBuffer: MTLBuffer?
    private var thresholdBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?

    // Triple buffering semaphore to prevent queue saturation
    private let frameSemaphore = DispatchSemaphore(value: 3)
    private let resourceLock = NSLock()

    // Internal Structs matching Metal Shading Language layout exactly
    public struct PeakingUniforms {
        var inputWidth: UInt32
        var inputHeight: UInt32
        var workWidth: UInt32
        var workHeight: UInt32
        var targetWidth: UInt32
        var targetHeight: UInt32
        var sensitivity: Float
        var iso: Float
        var colorR: Float
        var colorG: Float
        var colorB: Float
        var colorA: Float
        var pointThickness: Float
        var displayScale: Float
        var minLumaClip: Float
        var maxLumaClip: Float
    }

    public struct ThresholdBufferData {
        var rawThreshold: Float
        var emaThreshold: Float
        var activePixelCount: UInt32
        var totalPixelCount: UInt32
    }

    // MARK: - Initialization

    public init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()

        if let dev = dev {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &self.textureCache)
            self.setupPipelines(device: dev)
            self.setupBuffers(device: dev)
        }
    }

    private func setupPipelines(device: MTLDevice) {
        var library: MTLLibrary? = device.makeDefaultLibrary()

        // Fallback: Nếu môi trường chạy chưa build .metal vào default.metallib, load trực tiếp từ file hoặc source
        if library?.makeFunction(name: "peakingDownscaleAndLumaKernel") == nil {
            if let bundlePath = Bundle.main.path(forResource: "FocusPeakingShaders", ofType: "metal"),
               let source = try? String(contentsOfFile: bundlePath, encoding: .utf8) {
                library = try? device.makeLibrary(source: source, options: nil)
            }
        }

        guard let lib = library else { return }

        if let fn = lib.makeFunction(name: "peakingDownscaleAndLumaKernel") {
            self.downscaleLumaPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = lib.makeFunction(name: "peakingFusedScharrDefocusKernel") {
            self.fusedScharrPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = lib.makeFunction(name: "peakingSharpnessHistogramKernel") {
            self.histogramPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = lib.makeFunction(name: "peakingAdaptiveThresholdKernel") {
            self.adaptiveThresholdPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = lib.makeFunction(name: "peakingThinningAndHysteresisKernel") {
            self.thinningPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = lib.makeFunction(name: "peakingTemporalFilterKernel") {
            self.temporalPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = lib.makeFunction(name: "peakingCompositeOverlayKernel") {
            self.compositePipeline = try? device.makeComputePipelineState(function: fn)
        }
    }

    private func setupBuffers(device: MTLDevice) {
        self.histogramBuffer = device.makeBuffer(
            length: 64 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )
        self.activePixelCountBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )
        self.thresholdBuffer = device.makeBuffer(
            length: MemoryLayout<ThresholdBufferData>.stride,
            options: .storageModeShared
        )
        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<PeakingUniforms>.stride,
            options: .storageModeShared
        )

        // Khởi tạo giá trị EMA threshold ban đầu
        if let tb = self.thresholdBuffer {
            var initData = ThresholdBufferData(
                rawThreshold: 0.05,
                emaThreshold: 0.05,
                activePixelCount: 0,
                totalPixelCount: 0
            )
            memcpy(tb.contents(), &initData, MemoryLayout<ThresholdBufferData>.size)
        }
    }

    // MARK: - Resource Allocation & Texture Cache Management

    private func ensureIntermediateTextures(device: MTLDevice, workWidth: Int, workHeight: Int) {
        if lumaWorkTexture != nil && currentWorkWidth == workWidth && currentWorkHeight == workHeight {
            return
        }

        currentWorkWidth = workWidth
        currentWorkHeight = workHeight

        // 1. Luma Work Texture (r8Unorm, Private Storage)
        let lumaDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: workWidth,
            height: workHeight,
            mipmapped: false
        )
        lumaDesc.usage = [.shaderRead, .shaderWrite]
        lumaDesc.storageMode = .private
        self.lumaWorkTexture = device.makeTexture(descriptor: lumaDesc)

        // 2. Sharpness & Gradient Normal Direction (rg16Float, Private Storage)
        let sharpDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width: workWidth,
            height: workHeight,
            mipmapped: false
        )
        sharpDesc.usage = [.shaderRead, .shaderWrite]
        sharpDesc.storageMode = .private
        self.sharpnessTexture = device.makeTexture(descriptor: sharpDesc)

        // 3. Candidate Thinned Mask (r8Unorm, Private Storage)
        let maskDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: workWidth,
            height: workHeight,
            mipmapped: false
        )
        maskDesc.usage = [.shaderRead, .shaderWrite]
        maskDesc.storageMode = .private
        self.candidateMaskTexture = device.makeTexture(descriptor: maskDesc)

        // 4. Ping-Pong Temporal Textures (r8Unorm, Private Storage)
        self.pingPongTextures[0] = device.makeTexture(descriptor: maskDesc)
        self.pingPongTextures[1] = device.makeTexture(descriptor: maskDesc)
        self.currentPingPongIndex = 0
    }

    // MARK: - Zero-Copy Texture Ingestion from CVPixelBuffer

    public func makeTextureFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var cvTexture: CVMetalTexture?
        if pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // Đọc trực tiếp kênh Y Plane (Plane 0) ở định dạng .r8Unorm không tốn chi phí copy
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .r8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
        } else {
            // Chuẩn 32BGRA
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
        }

        guard let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    // MARK: - Core Multi-Pass GPU Execution

    public func renderFocusPeaking(
        sourcePixelBuffer: CVPixelBuffer?,
        sourceTexture: MTLTexture?,
        targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        color: (r: Float, g: Float, b: Float, a: Float),
        sensitivity: Float,
        iso: Float,
        displayScale: Float = 2.0
    ) {
        guard let device = self.device else { return }

        // Pipeline validation
        guard let downscalePipeline = self.downscaleLumaPipeline,
              let fusedScharrPipe = self.fusedScharrPipeline,
              let histPipe = self.histogramPipeline,
              let adaptPipe = self.adaptiveThresholdPipeline,
              let thinPipe = self.thinningPipeline,
              let tempPipe = self.temporalPipeline,
              let compPipe = self.compositePipeline,
              let histBuf = self.histogramBuffer,
              let activeCountBuf = self.activePixelCountBuffer,
              let threshBuf = self.thresholdBuffer,
              let uniBuf = self.uniformsBuffer else {
            return
        }

        // Lấy source texture (ưu tiên texture đã có, nếu chưa có thì wrap từ CVPixelBuffer)
        let inputTex: MTLTexture?
        if let sTex = sourceTexture {
            inputTex = sTex
        } else if let pb = sourcePixelBuffer {
            inputTex = makeTextureFromPixelBuffer(pb)
        } else {
            inputTex = nil
        }
        guard let inTexture = inputTex else { return }

        resourceLock.lock()
        defer { resourceLock.unlock() }

        let inW = inTexture.width
        let inH = inTexture.height
        let targetW = targetTexture.width
        let targetH = targetTexture.height

        // Tính toán độ phân giải làm việc tối ưu (Cân bằng độ nét và hiệu năng: cạnh dài tối đa 1280px)
        let maxWorkDim = 1280
        let maxSide = max(inW, inH)
        let workScale = (maxSide > maxWorkDim && maxSide > 0) ? (Float(maxWorkDim) / Float(maxSide)) : 1.0
        let workW = max(32, (Int(Float(inW) * workScale) / 16) * 16)
        let workH = max(32, (Int(Float(inH) * workScale) / 16) * 16)

        ensureIntermediateTextures(device: device, workWidth: workW, workHeight: workH)

        guard let lumaWork = self.lumaWorkTexture,
              let sharpnessTex = self.sharpnessTexture,
              let candidateMask = self.candidateMaskTexture,
              let prevPingPong = self.pingPongTextures[currentPingPongIndex],
              let nextPingPong = self.pingPongTextures[1 - currentPingPongIndex] else {
            return
        }

        // Nạp tham số PeakingUniforms
        var uniforms = PeakingUniforms(
            inputWidth: UInt32(inW),
            inputHeight: UInt32(inH),
            workWidth: UInt32(workW),
            workHeight: UInt32(workH),
            targetWidth: UInt32(targetW),
            targetHeight: UInt32(targetH),
            sensitivity: max(0.0, min(1.0, sensitivity)),
            iso: max(25.0, iso),
            colorR: color.r,
            colorG: color.g,
            colorB: color.b,
            colorA: color.a,
            pointThickness: 1.5,
            displayScale: displayScale,
            minLumaClip: 4.0 / 255.0,
            maxLumaClip: 250.0 / 255.0
        )
        memcpy(uniBuf.contents(), &uniforms, MemoryLayout<PeakingUniforms>.size)

        // THỰC THI CHUỖI COMPUTE PASS TRÊN GPU

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "CinematicFocusPeakingPipeline"

        let threadsPerThreadgroup16x16 = MTLSize(width: 16, height: 16, depth: 1)
        let workGridSize = MTLSize(
            width: (workW + 15) / 16 * 16,
            height: (workH + 15) / 16 * 16,
            depth: 1
        )

        // PASS 1: Trích xuất Luma Rec.709 & Box Filter 2x2 Downscale
        encoder.setComputePipelineState(downscalePipeline)
        encoder.setTexture(inTexture, index: 0)
        encoder.setTexture(lumaWork, index: 1)
        encoder.setBuffer(uniBuf, offset: 0, index: 0)
        encoder.dispatchThreads(workGridSize, threadsPerThreadgroup: threadsPerThreadgroup16x16)

        encoder.memoryBarrier(scope: .textures)

        // PASS 2: Fused Tile Scharr + Re-Blur Defocus Gradient Ratio + Clip Mask
        encoder.setComputePipelineState(fusedScharrPipe)
        encoder.setTexture(lumaWork, index: 0)
        encoder.setTexture(sharpnessTex, index: 1)
        encoder.setBuffer(uniBuf, offset: 0, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (workW + 15) / 16, height: (workH + 15) / 16, depth: 1),
            threadsPerThreadgroup: threadsPerThreadgroup16x16
        )

        encoder.memoryBarrier(scope: [.buffers, .textures])

        // PASS 3: Tính toán Histogram 64-Bin độ nét trên GPU
        encoder.setComputePipelineState(histPipe)
        encoder.setTexture(sharpnessTex, index: 0)
        encoder.setBuffer(histBuf, offset: 0, index: 0)
        encoder.setBuffer(activeCountBuf, offset: 0, index: 1)
        encoder.setBuffer(uniBuf, offset: 0, index: 2)
        encoder.dispatchThreads(workGridSize, threadsPerThreadgroup: threadsPerThreadgroup16x16)

        encoder.memoryBarrier(scope: .buffers)

        // PASS 4: Tính ngưỡng động Adaptive Threshold theo Percentile & EMA
        encoder.setComputePipelineState(adaptPipe)
        encoder.setBuffer(histBuf, offset: 0, index: 0)
        encoder.setBuffer(activeCountBuf, offset: 0, index: 1)
        encoder.setBuffer(threshBuf, offset: 0, index: 2)
        encoder.setBuffer(uniBuf, offset: 0, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))

        encoder.memoryBarrier(scope: [.buffers, .textures])

        // PASS 5: NMS Làm mỏng đường viền 1px, Hysteresis & Khử hạt rời rạc Despeckle
        encoder.setComputePipelineState(thinPipe)
        encoder.setTexture(sharpnessTex, index: 0)
        encoder.setTexture(candidateMask, index: 1)
        encoder.setBuffer(threshBuf, offset: 0, index: 0)
        encoder.setBuffer(uniBuf, offset: 0, index: 1)
        encoder.dispatchThreads(workGridSize, threadsPerThreadgroup: threadsPerThreadgroup16x16)

        encoder.memoryBarrier(scope: .textures)

        // PASS 6: Bộ lọc thời gian Ping-Pong (Fast Attack, Smooth Decay)
        encoder.setComputePipelineState(tempPipe)
        encoder.setTexture(candidateMask, index: 0)
        encoder.setTexture(prevPingPong, index: 1)
        encoder.setTexture(nextPingPong, index: 2)
        encoder.setBuffer(uniBuf, offset: 0, index: 0)
        encoder.dispatchThreads(workGridSize, threadsPerThreadgroup: threadsPerThreadgroup16x16)

        // Hoán đổi buffer ping-pong
        currentPingPongIndex = 1 - currentPingPongIndex

        encoder.memoryBarrier(scope: .textures)

        // PASS 7: Phủ màu viền báo nét khử răng cưa trực tiếp lên Preview Texture
        encoder.setComputePipelineState(compPipe)
        encoder.setTexture(targetTexture, index: 0)
        encoder.setTexture(nextPingPong, index: 1)
        encoder.setBuffer(uniBuf, offset: 0, index: 0)

        let targetGridSize = MTLSize(
            width: (targetW + 15) / 16 * 16,
            height: (targetH + 15) / 16 * 16,
            depth: 1
        )
        encoder.dispatchThreads(targetGridSize, threadsPerThreadgroup: threadsPerThreadgroup16x16)

        encoder.endEncoding()

        #if DEBUG
        commandBuffer.addCompletedHandler { cb in
            let gpuTime = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
            if gpuTime > 3.0 {
                CameraLogger.warning("FocusPeaking: GPU time cao: \(String(format: "%.2f", gpuTime)) ms", category: .performance)
            }
        }
        #endif
    }

    // MARK: - Legacy Compatibility API

    public func processPeaking(
        inputImage: CIImage,
        color: FocusPeakingColor,
        threshold: Float = 0.16
    ) -> CIImage {
        // Tương thích ngược an toàn cho các caller CIImage cũ
        return inputImage
    }
}
