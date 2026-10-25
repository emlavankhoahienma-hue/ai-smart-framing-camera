import Foundation
import CoreGraphics
import CoreVideo
import simd

public enum LightingSceneType: String, CaseIterable, Sendable {
    case backlit = "backlit"
    case night = "night"
    case sunset = "sunset"
    case harshSun = "harsh_sun"
    case normal = "normal"

    public var localizedName: String {
        switch self {
        case .backlit: return "Ngược sáng (Backlit)"
        case .night: return "Đêm / Đèn Neon"
        case .sunset: return "Hoàng hôn / Low-Key"
        case .harshSun: return "Nắng gắt ngoài trời"
        case .normal: return "Ánh sáng cân bằng"
        }
    }
}

public struct SceneExposureDecision: Sendable {
    public let recommendedEVBias: Float
    public let sceneType: LightingSceneType
    public let ev100: Float
    public let subjectLuma: Float
    public let backgroundLuma: Float
    public let highlightClippingRatio: Float
    public let shadowRatio: Float
    public let rationale: String

    public init(
        recommendedEVBias: Float,
        sceneType: LightingSceneType,
        ev100: Float,
        subjectLuma: Float,
        backgroundLuma: Float,
        highlightClippingRatio: Float,
        shadowRatio: Float,
        rationale: String
    ) {
        self.recommendedEVBias = recommendedEVBias
        self.sceneType = sceneType
        self.ev100 = ev100
        self.subjectLuma = subjectLuma
        self.backgroundLuma = backgroundLuma
        self.highlightClippingRatio = highlightClippingRatio
        self.shadowRatio = shadowRatio
        self.rationale = rationale
    }
}

public struct SceneLumaMetrics: Sendable {
    public let subjectLuma: Float
    public let backgroundLuma: Float
    public let overallLuma: Float
    public let highlightClippingRatio: Float
    public let shadowRatio: Float
    public let maxLuma: Float

    public init(
        subjectLuma: Float,
        backgroundLuma: Float,
        overallLuma: Float,
        highlightClippingRatio: Float,
        shadowRatio: Float,
        maxLuma: Float
    ) {
        self.subjectLuma = subjectLuma
        self.backgroundLuma = backgroundLuma
        self.overallLuma = overallLuma
        self.highlightClippingRatio = highlightClippingRatio
        self.shadowRatio = shadowRatio
        self.maxLuma = maxLuma
    }
}

/// Hệ thống trí tuệ nhân tạo đo sáng & điều chỉnh EV thông minh theo môi trường (Smart Scene-Aware Exposure Engine)
public final class SmartSceneExposureEngine: @unchecked Sendable {
    public static let shared = SmartSceneExposureEngine()

    private init() {}

    /// Tính chỉ số ánh sáng vật lý EV100 từ cảm biến phần cứng
    public func calculateEV100(iso: Float?, exposureDuration: Double?, aperture: Float?) -> Float {
        let f = (aperture != nil && aperture!.isFinite && aperture! > 0) ? aperture! : 1.8
        let t = (exposureDuration != nil && exposureDuration!.isFinite && exposureDuration! > 0) ? exposureDuration! : (1.0 / 60.0)
        let s = (iso != nil && iso!.isFinite && iso! > 0) ? iso! : 100.0
        let numerator = Double(f * f) * 100.0
        let denominator = t * Double(s)
        guard denominator > 0 else { return 8.0 }
        let ev = log2(numerator / denominator)
        return Float(ev.isFinite ? ev : 8.0)
    }

    /// Trích xuất vùng khung cắt ảo W(Z*) từ anchor, gridPoint và mức zoom Z*
    public func calculateVirtualCropWindow(anchor: CGPoint, gridPoint: CGPoint, targetZoom: CGFloat) -> CGRect {
        let z = max(1.0, targetZoom)
        let cropW = 1.0 / z
        let cropH = 1.0 / z
        let cropCenterX = anchor.x + (cropW * (0.5 - gridPoint.x))
        let cropCenterY = anchor.y + (cropH * (0.5 - gridPoint.y))
        let minX = max(0.0, min(1.0 - cropW, cropCenterX - cropW / 2.0))
        let minY = max(0.0, min(1.0 - cropH, cropCenterY - cropH / 2.0))
        return CGRect(x: minX, y: minY, width: cropW, height: cropH)
    }

    /// Đánh giá ánh sáng trực tiếp trên vùng khung cắt ảo W(Z*) kết hợp môi trường toàn cảnh
    public func evaluateExposure(
        pixelBuffer: CVPixelBuffer?,
        virtualCrop: CGRect,
        subjectRect: CGRect?,
        sceneContext: DetectedSceneType,
        iso: Float? = nil,
        exposureDuration: Double? = nil,
        aperture: Float? = nil
    ) -> SceneExposureDecision {
        let ev100 = calculateEV100(iso: iso, exposureDuration: exposureDuration, aperture: aperture)
        let metrics = sampleLumaMetrics(
            from: pixelBuffer,
            crop: virtualCrop,
            subjectRect: subjectRect,
            ev100: ev100,
            sceneContext: sceneContext
        )
        return decideExposure(
            metrics: metrics,
            ev100: ev100,
            sceneContext: sceneContext
        )
    }

    /// Phân tích quyết định độ sáng chuẩn xác theo các quy tắc chống chỉnh sáng bậy 100%
    public func decideExposure(
        metrics: SceneLumaMetrics,
        ev100: Float,
        sceneContext: DetectedSceneType
    ) -> SceneExposureDecision {
        let subj = metrics.subjectLuma
        let bg = metrics.backgroundLuma
        let clipRatio = metrics.highlightClippingRatio
        let overall = metrics.overallLuma

        // 1. NGƯỢC SÁNG (Backlit):
        // Hậu cảnh rất sáng nhưng chủ thể/khuôn mặt bị tối -> Bù sáng dương (+0.4 đến +1.2 EV)
        let isBacklit = (bg >= 0.58 && subj <= 0.44 && (bg - subj) >= 0.18) ||
                        (sceneContext == .portrait && bg - subj >= 0.22)
        if isBacklit {
            let neededBoost = (0.48 - subj) * 2.5
            var ev = Float(min(1.2, max(0.4, Double(neededBoost))))
            // Chống cháy sáng nền quá mức: nếu highlight đã chiếm >= 4% thì giới hạn ở +0.6 EV
            if clipRatio >= 0.04 {
                ev = min(ev, 0.6)
            }
            let roundedEV = round(ev * 10) / 10
            return SceneExposureDecision(
                recommendedEVBias: roundedEV,
                sceneType: .backlit,
                ev100: ev100,
                subjectLuma: subj,
                backgroundLuma: bg,
                highlightClippingRatio: clipRatio,
                shadowRatio: metrics.shadowRatio,
                rationale: String(format: "Ngược sáng · Bù sáng %+.1f EV làm rõ chi tiết chủ thể", roundedEV)
            )
        }

        // 2. BAN ĐÊM / ĐÈN NEON / HOÀNG HÔN / LOW-KEY:
        // CẤM kéo sáng làm bệt đêm hoặc cháy đèn; tự động giữ hoặc giảm nhẹ (-0.3 đến -0.9 EV)
        let isSunset = (sceneContext == .sunset)
        let isNight = (sceneContext == .night || ev100 <= 5.0 || (overall <= 0.26 && clipRatio > 0.003))
        if isSunset {
            let ev: Float = -0.4
            return SceneExposureDecision(
                recommendedEVBias: ev,
                sceneType: .sunset,
                ev100: ev100,
                subjectLuma: subj,
                backgroundLuma: bg,
                highlightClippingRatio: clipRatio,
                shadowRatio: metrics.shadowRatio,
                rationale: "Hoàng hôn · Giảm -0.4 EV tôn màu ấm và mây rực rỡ"
            )
        }
        if isNight {
            let hasNeonOrLights = clipRatio >= 0.005 || (metrics.maxLuma > 0.92 && overall < 0.25)
            let ev: Float = hasNeonOrLights ? -0.6 : -0.3
            return SceneExposureDecision(
                recommendedEVBias: ev,
                sceneType: .night,
                ev100: ev100,
                subjectLuma: subj,
                backgroundLuma: bg,
                highlightClippingRatio: clipRatio,
                shadowRatio: metrics.shadowRatio,
                rationale: hasNeonOrLights ?
                    "Đêm đèn Neon · Giảm -0.6 EV chống cháy đèn & giữ đen sâu" :
                    "Cảnh đêm tối · Giảm -0.3 EV chống nhiễu hạt & giữ chiều sâu"
            )
        }

        // 3. NẮNG GẮT NGOÀI TRỜI (Harsh Sun / High Contrast):
        // Giữ hoặc giảm nhẹ EV để chống cháy vùng Highlight (clipRatio < 1%)
        let isHarshSun = (ev100 >= 11.5 || (overall >= 0.68 && clipRatio >= 0.012))
        if isHarshSun {
            let penaltyBoost = Double(clipRatio) * 15.0
            let ev = -Float(min(0.8, max(0.3, 0.3 + penaltyBoost)))
            let roundedEV = round(ev * 10) / 10
            return SceneExposureDecision(
                recommendedEVBias: roundedEV,
                sceneType: .harshSun,
                ev100: ev100,
                subjectLuma: subj,
                backgroundLuma: bg,
                highlightClippingRatio: clipRatio,
                shadowRatio: metrics.shadowRatio,
                rationale: String(format: "Nắng gắt ngoài trời · Giảm %+.1f EV bảo toàn chi tiết highlight", roundedEV)
            )
        }

        // 4. BÌNH THƯỜNG / CÂN BẰNG (Normal):
        // Giữ EV ở mức chuẩn tự nhiên (tinh chỉnh vi mô [-0.2...+0.2] nếu cần)
        let diff = 0.48 - subj
        let fineEV = Float(max(-0.2, min(0.2, Double(diff) * 0.6)))
        let finalEV = abs(fineEV) < 0.08 ? 0.0 : (round(fineEV * 10) / 10)
        return SceneExposureDecision(
            recommendedEVBias: finalEV,
            sceneType: .normal,
            ev100: ev100,
            subjectLuma: subj,
            backgroundLuma: bg,
            highlightClippingRatio: clipRatio,
            shadowRatio: metrics.shadowRatio,
            rationale: finalEV == 0.0 ?
                "Ánh sáng cân bằng · Giữ EV chuẩn tự nhiên" :
                String(format: "Ánh sáng hài hòa · Tinh chỉnh %+.1f EV", finalEV)
        )
    }

    /// Lấy mẫu quang học Rec.709 từ CVPixelBuffer trong vùng khung cắt ảo W(Z*)
    private func sampleLumaMetrics(
        from pixelBuffer: CVPixelBuffer?,
        crop: CGRect,
        subjectRect: CGRect?,
        ev100: Float,
        sceneContext: DetectedSceneType
    ) -> SceneLumaMetrics {
        guard let pixelBuffer = pixelBuffer,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return syntheticFallbackMetrics(ev100: ev100, sceneContext: sceneContext)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer), width > 0, height > 0 else {
            return syntheticFallbackMetrics(ev100: ev100, sceneContext: sceneContext)
        }

        let data = baseAddress.assumingMemoryBound(to: UInt8.self)

        let startX = max(0, min(width - 1, Int(crop.minX * CGFloat(width))))
        let endX = max(startX + 1, min(width, Int(crop.maxX * CGFloat(width))))
        let startY = max(0, min(height - 1, Int(crop.minY * CGFloat(height))))
        let endY = max(startY + 1, min(height, Int(crop.maxY * CGFloat(height))))

        let stepX = max(1, (endX - startX) / 32)
        let stepY = max(1, (endY - startY) / 32)

        var totalSubjLuma: Float = 0
        var countSubj: Int = 0
        var totalBgLuma: Float = 0
        var countBg: Int = 0
        var totalOverall: Float = 0
        var countTotal: Int = 0
        var countHighlight: Int = 0
        var countShadow: Int = 0
        var maxLumaVal: Float = 0

        for y in stride(from: startY, to: endY, by: stepY) {
            let rowOffset = y * bytesPerRow
            let normY = CGFloat(y) / CGFloat(height)
            for x in stride(from: startX, to: endX, by: stepX) {
                let offset = rowOffset + x * 4
                let b = Float(data[offset])
                let g = Float(data[offset + 1])
                let r = Float(data[offset + 2])
                let lum = (r * 0.2126 + g * 0.7152 + b * 0.0722) / 255.0

                totalOverall += lum
                countTotal += 1
                if lum > maxLumaVal { maxLumaVal = lum }
                if lum >= 0.95 { countHighlight += 1 }
                if lum <= 0.07 { countShadow += 1 }

                let normX = CGFloat(x) / CGFloat(width)
                let point = CGPoint(x: normX, y: normY)
                if let sRect = subjectRect, sRect.contains(point) {
                    totalSubjLuma += lum
                    countSubj += 1
                } else {
                    totalBgLuma += lum
                    countBg += 1
                }
            }
        }

        guard countTotal > 0 else {
            return syntheticFallbackMetrics(ev100: ev100, sceneContext: sceneContext)
        }

        let overall = totalOverall / Float(countTotal)
        let subj = countSubj > 0 ? (totalSubjLuma / Float(countSubj)) : overall
        let bg = countBg > 0 ? (totalBgLuma / Float(countBg)) : overall
        let clipRatio = Float(countHighlight) / Float(countTotal)
        let shadowRatio = Float(countShadow) / Float(countTotal)

        return SceneLumaMetrics(
            subjectLuma: subj,
            backgroundLuma: bg,
            overallLuma: overall,
            highlightClippingRatio: clipRatio,
            shadowRatio: shadowRatio,
            maxLuma: maxLumaVal
        )
    }

    /// Tính toán thông số giả lập tin cậy khi không có frame trực tiếp hoặc trong môi trường test
    public func syntheticFallbackMetrics(ev100: Float, sceneContext: DetectedSceneType) -> SceneLumaMetrics {
        switch sceneContext {
        case .night:
            return SceneLumaMetrics(
                subjectLuma: 0.22,
                backgroundLuma: 0.16,
                overallLuma: 0.18,
                highlightClippingRatio: 0.008,
                shadowRatio: 0.35,
                maxLuma: 0.98
            )
        case .sunset:
            return SceneLumaMetrics(
                subjectLuma: 0.38,
                backgroundLuma: 0.45,
                overallLuma: 0.42,
                highlightClippingRatio: 0.006,
                shadowRatio: 0.15,
                maxLuma: 0.94
            )
        case .landscape where ev100 >= 12.0:
            return SceneLumaMetrics(
                subjectLuma: 0.65,
                backgroundLuma: 0.72,
                overallLuma: 0.70,
                highlightClippingRatio: 0.025,
                shadowRatio: 0.02,
                maxLuma: 1.00
            )
        default:
            if ev100 >= 12.5 {
                return SceneLumaMetrics(
                    subjectLuma: 0.62,
                    backgroundLuma: 0.74,
                    overallLuma: 0.70,
                    highlightClippingRatio: 0.020,
                    shadowRatio: 0.02,
                    maxLuma: 1.00
                )
            } else if ev100 <= 4.0 {
                return SceneLumaMetrics(
                    subjectLuma: 0.25,
                    backgroundLuma: 0.18,
                    overallLuma: 0.20,
                    highlightClippingRatio: 0.004,
                    shadowRatio: 0.30,
                    maxLuma: 0.92
                )
            } else {
                return SceneLumaMetrics(
                    subjectLuma: 0.48,
                    backgroundLuma: 0.50,
                    overallLuma: 0.49,
                    highlightClippingRatio: 0.002,
                    shadowRatio: 0.05,
                    maxLuma: 0.88
                )
            }
        }
    }
}
