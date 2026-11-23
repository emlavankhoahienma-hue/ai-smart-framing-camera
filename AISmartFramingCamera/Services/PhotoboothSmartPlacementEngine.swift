import Foundation
import CoreGraphics
import Vision

/// Kết quả phân tích khuôn mặt & vùng trống siêu nhẹ (chạy trực tiếp bằng Apple Vision Neural Engine, 0 MB dung lượng phụ).
public struct PhotoboothSlotSemanticMap: Sendable {
    public struct FaceAnchors: Sendable {
        public let faceBoxInStrip: CGRect       // Tọa độ chuẩn hóa [0...1] trên toàn dải ảnh
        public let headCrown: CGPoint           // Trên đỉnh đầu (tai thỏ, tai mèo, vương miện)
        public let eyeBridge: CGPoint           // Sống mũi giữa 2 mắt (kính râm)
        public let leftTemple: CGPoint          // Kẹp tóc / thái dương trái
        public let rightTemple: CGPoint         // Kẹp tóc / thái dương phải
        public let leftCheek: CGPoint           // Gò má trái ngoài (dấu son, tim nhỏ, cherry)
        public let rightCheek: CGPoint          // Gò má phải ngoài
        public let leftShoulder: CGPoint        // Vai trái (cánh, gấu bông)
        public let rightShoulder: CGPoint       // Vai phải
        public let faceWidthInStrip: CGFloat    // Độ rộng khuôn mặt theo tỷ lệ chiều rộng dải ảnh
        public let rollDegrees: Double          // Góc nghiêng đầu thực tế (-38...38 độ)
        public let openSideIsRight: Bool        // Phía nào có khoảng trống rộng hơn trong khung
    }

    public let slotIndex: Int
    public let slotRectInStrip: CGRect
    public let faces: [FaceAnchors]
    public let safeCornersInStrip: [CGPoint]    // Các góc trống đã chấm điểm xa khuôn mặt nhất
}

/// Bộ định vị Sticker thông minh đa vùng (Đỉnh đầu · Mắt · Thái dương · Gò má · Bên vai · Góc trống không che mặt).
public enum PhotoboothSmartPlacementEngine {

    // MARK: - 1. Phân tích toàn bộ các khung ảnh (Vision Face Landmarks + Negative Space Scoring)

    public static func analyzeSlots(
        slots: [PhotoboothSlotPhoto?],
        config: PhotoboothStripConfig
    ) async -> [PhotoboothSlotSemanticMap] {
        let canvasSize = config.layout.canvasSize
        let slotRects = config.layout.slotRects(in: canvasSize, marginScale: config.marginScale)

        // Đóng gói snapshot nhẹ an toàn Sendable trước khi chạy nền
        struct SlotInput: @unchecked Sendable {
            let index: Int
            let image: CGImage
            let isMirrored: Bool
            let rect: CGRect
        }

        var inputs: [SlotInput] = []
        for rectIdx in 0..<slotRects.count {
            let photoIdx = config.layout.photoIndex(forRenderedRectIndex: rectIdx)
            if photoIdx < slots.count, let slot = slots[photoIdx] {
                inputs.append(SlotInput(index: rectIdx, image: slot.displayImage, isMirrored: slot.isMirrored, rect: slotRects[rectIdx]))
            }
        }

        return await Task.detached(priority: .userInitiated) {
            var maps: [PhotoboothSlotSemanticMap] = []
            maps.reserveCapacity(inputs.count)
            for item in inputs {
                let map = analyzeSingleSlotSync(
                    slotIndex: item.index,
                    cgImage: item.image,
                    isMirrored: item.isMirrored,
                    slotRect: item.rect,
                    canvasSize: canvasSize
                )
                maps.append(map)
            }
            return maps
        }.value
    }

    // MARK: - 2. Tính vị trí chuẩn xác cho 1 Sticker khi người dùng chạm chọn

    public static func suggestPlacement(
        for asset: PhotoboothStickerAsset,
        maps: [PhotoboothSlotSemanticMap],
        existingStickers: [PlacedPhotoboothSticker],
        config: PhotoboothStripConfig
    ) -> PlacedPhotoboothSticker {
        let preferredZone = asset.anchorZone
        var candidates: [(point: CGPoint, scale: CGFloat, rotation: Double, score: Double)] = []

        for map in maps {
            let slotWNorm = map.slotRectInStrip.width
            switch preferredZone {
            case .headCrown:
                for face in map.faces {
                    let s = clampScale(face.faceWidthInStrip * 1.18, min: 0.14, max: 0.36)
                    let score = 100.0 - overlapPenalty(at: face.headCrown, existing: existingStickers) * 180.0
                    candidates.append((face.headCrown, s, face.rollDegrees, score))
                }
            case .eyeBridge:
                for face in map.faces {
                    let s = clampScale(face.faceWidthInStrip * 0.96, min: 0.12, max: 0.32)
                    let score = 100.0 - overlapPenalty(at: face.eyeBridge, existing: existingStickers) * 180.0
                    candidates.append((face.eyeBridge, s, face.rollDegrees, score))
                }
            case .hairTemple:
                for face in map.faces {
                    let primary = face.openSideIsRight ? face.rightTemple : face.leftTemple
                    let secondary = face.openSideIsRight ? face.leftTemple : face.rightTemple
                    let s = clampScale(face.faceWidthInStrip * 0.56, min: 0.10, max: 0.24)
                    for (idx, pt) in [primary, secondary].enumerated() {
                        let bias = idx == 0 ? 6.0 : 0.0
                        let tilt = face.rollDegrees + (pt == face.rightTemple ? 10.0 : -10.0)
                        let score = 96.0 + bias - overlapPenalty(at: pt, existing: existingStickers) * 160.0
                        candidates.append((pt, s, tilt, score))
                    }
                }
            case .cheekAccent:
                for face in map.faces {
                    let primary = face.openSideIsRight ? face.rightCheek : face.leftCheek
                    let secondary = face.openSideIsRight ? face.leftCheek : face.rightCheek
                    let s = clampScale(face.faceWidthInStrip * 0.36, min: 0.085, max: 0.18)
                    for (idx, pt) in [primary, secondary].enumerated() {
                        let bias = idx == 0 ? 5.0 : 0.0
                        let tilt = face.rollDegrees + (pt == face.rightCheek ? 8.0 : -8.0)
                        let score = 94.0 + bias - overlapPenalty(at: pt, existing: existingStickers) * 160.0
                        candidates.append((pt, s, tilt, score))
                    }
                }
            case .shoulderBack:
                for face in map.faces {
                    let primary = face.openSideIsRight ? face.rightShoulder : face.leftShoulder
                    let secondary = face.openSideIsRight ? face.leftShoulder : face.rightShoulder
                    let s = clampScale(face.faceWidthInStrip * 0.72, min: 0.13, max: 0.28)
                    for (idx, pt) in [primary, secondary].enumerated() {
                        let bias = idx == 0 ? 5.0 : 0.0
                        let score = 90.0 + bias - overlapPenalty(at: pt, existing: existingStickers) * 160.0
                        candidates.append((pt, s, face.rollDegrees * 0.4, score))
                    }
                }
            case .safeCorner:
                let cornerScale = clampScale(slotWNorm * 0.23, min: 0.13, max: 0.24)
                for (cIdx, pt) in map.safeCornersInStrip.enumerated() {
                    let orderBonus = Double(max(0, 6 - cIdx)) * 3.0
                    let tilt = (cIdx % 2 == 0) ? -7.0 : 7.0
                    let score = 80.0 + orderBonus - overlapPenalty(at: pt, existing: existingStickers) * 170.0
                    candidates.append((pt, cornerScale, tilt, score))
                }
            }

            // Luôn bổ sung fallback góc trống nếu khung không phát hiện mặt
            if map.faces.isEmpty && preferredZone != .safeCorner {
                let fallbackScale = clampScale(slotWNorm * 0.22, min: 0.13, max: 0.24)
                for (cIdx, pt) in map.safeCornersInStrip.prefix(2).enumerated() {
                    let score = 45.0 - Double(cIdx) * 3.0 - overlapPenalty(at: pt, existing: existingStickers) * 150.0
                    candidates.append((pt, fallbackScale, cIdx == 0 ? -6.0 : 6.0, score))
                }
            }
        }

        // Bổ sung 2 góc trang trí ở chân trang dải ảnh nếu toàn bộ khung đều chật
        let footerLeft = CGPoint(x: 0.16, y: 0.935)
        let footerRight = CGPoint(x: 0.84, y: 0.935)
        for (idx, pt) in [footerLeft, footerRight].enumerated() {
            let score = 30.0 - overlapPenalty(at: pt, existing: existingStickers) * 120.0
            candidates.append((pt, 0.16, idx == 0 ? -8.0 : 8.0, score))
        }

        if let best = candidates.max(by: { $0.score < $1.score }) {
            return PlacedPhotoboothSticker(
                assetID: asset.id,
                assetSource: asset.source,
                normalizedX: max(0.06, min(0.94, best.point.x)),
                normalizedY: max(0.05, min(0.95, best.point.y)),
                scale: best.scale,
                rotationDegrees: best.rotation,
                opacity: 1.0
            )
        }

        let fallback = fallbackCenterPoint(config: config)
        return PlacedPhotoboothSticker(
            assetID: asset.id,
            assetSource: asset.source,
            normalizedX: fallback.x,
            normalizedY: fallback.y,
            scale: 0.20,
            rotationDegrees: 0,
            opacity: 1.0
        )
    }

    // MARK: - 3. Tự động trang trí trọn dải ảnh 1 chạm (Phối đa vùng: Đỉnh đầu + Thái dương/Má + Góc trống + Chân trang)

    public static func generateAutoDecoratedStickers(
        style: PhotoboothAutoDecorateStyle,
        maps: [PhotoboothSlotSemanticMap],
        availableAssets: [PhotoboothStickerAsset],
        config: PhotoboothStripConfig
    ) -> [PlacedPhotoboothSticker] {
        let byID = Dictionary(uniqueKeysWithValues: availableAssets.map { ($0.id, $0) })

        let sequenceIDs: [String]
        switch style {
        case .smartAdaptive:
            // Phối hài hòa từng vị trí khác nhau trên từng ô: Tai thỏ / Kẹp mèo -> Nơ hồng -> Tim/Dấu son -> Lấp lánh & Hoa cúc
            sequenceIDs = ["pb_bunny_ears", "pb_kitty_clip", "pb_ribbon_pink", "pb_heart_doodle", "pb_star_scribble", "pb_daisy_flower", "pb_butterfly_silver", "pb_pastel_cloud"]
        case .coquette:
            sequenceIDs = ["pb_crown_silver", "pb_kitty_clip", "pb_ribbon_pink", "pb_cherry_twin", "pb_tulip_bouquet", "pb_strawberry_cake", "pb_angel_wings", "pb_teddy_head"]
        case .y2kRetro:
            sequenceIDs = ["pb_retro_sunglasses", "pb_headphone_y2k", "pb_butterfly_silver", "pb_chrome_star", "pb_kiss_mark", "pb_disco_ball", "pb_camera_mini", "pb_film_roll"]
        case .minimalCafe:
            sequenceIDs = ["pb_ribbon_black", "pb_iced_latte", "pb_tulip_bouquet", "pb_tape_washi", "pb_vintage_stamp", "pb_lucky_clover", "pb_camera_mini"]
        }

        let chosenAssets = sequenceIDs.compactMap { byID[$0] }
        guard !chosenAssets.isEmpty else { return [] }

        // Số lượng sticker vừa vặn theo số ô ảnh (tối giản tinh tế kiểu tiệm Hàn, không rối)
        let renderedCount = max(config.layout.slotCount, maps.count)
        let targetCount = min(chosenAssets.count, max(3, min(8, renderedCount)))
        var placed: [PlacedPhotoboothSticker] = []

        // Phân bổ rải đều qua từng khung ảnh để mỗi khung có điểm nhấn riêng, không lặp đè vào một mặt
        for idx in 0..<targetCount {
            let asset = chosenAssets[idx]
            let rotatedMaps: [PhotoboothSlotSemanticMap]
            if maps.count > 1 {
                let shift = idx % maps.count
                rotatedMaps = Array(maps[shift...]) + Array(maps[..<shift])
            } else {
                rotatedMaps = maps
            }
            let preferredMaps = rotatedMaps.isEmpty ? maps : [rotatedMaps[0]]
            var candidate = suggestPlacement(
                for: asset,
                maps: preferredMaps,
                existingStickers: placed,
                config: config
            )
            // Nếu ô đầu ưu tiên bị đè quá sát, mở rộng tìm trên tất cả các ô
            if overlapPenalty(at: CGPoint(x: candidate.normalizedX, y: candidate.normalizedY), existing: placed) > 0.35 {
                candidate = suggestPlacement(
                    for: asset,
                    maps: rotatedMaps,
                    existingStickers: placed,
                    config: config
                )
            }
            placed.append(candidate)
        }

        return placed
    }

    // MARK: - Private Vision & Aspect-Fill Coordinate Geometry

    private static func analyzeSingleSlotSync(
        slotIndex: Int,
        cgImage: CGImage,
        isMirrored: Bool,
        slotRect: CGRect,
        canvasSize: CGSize
    ) -> PhotoboothSlotSemanticMap {
        let imgW = CGFloat(max(1, cgImage.width))
        let imgH = CGFloat(max(1, cgImage.height))
        let canvasW = max(1.0, canvasSize.width)
        let canvasH = max(1.0, canvasSize.height)

        let normSlotRect = CGRect(
            x: slotRect.minX / canvasW,
            y: slotRect.minY / canvasH,
            width: slotRect.width / canvasW,
            height: slotRect.height / canvasH
        )

        // Chính xác toán học Aspect-Fill từ tọa độ ảnh gốc [0,1] (top-left) -> tọa độ toàn dải ảnh [0,1]
        let fillScale = max(slotRect.width / imgW, slotRect.height / imgH)
        let drawW = imgW * fillScale
        let drawH = imgH * fillScale
        let offsetX = (slotRect.width - drawW) * 0.5
        let offsetY = (slotRect.height - drawH) * 0.5

        func imageTopLeftToStrip(_ pt: CGPoint) -> CGPoint {
            let mx = isMirrored ? (1.0 - pt.x) : pt.x
            let pxInSlot = offsetX + mx * drawW
            let pyInSlot = offsetY + pt.y * drawH
            let sx = (slotRect.minX + pxInSlot) / canvasW
            let sy = (slotRect.minY + pyInSlot) / canvasH
            return CGPoint(x: sx, y: sy)
        }

        var detectedFaces: [PhotoboothSlotSemanticMap.FaceAnchors] = []

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        let faceRequest = VNDetectFaceLandmarksRequest()
        try? handler.perform([faceRequest])

        let observations = (faceRequest.results ?? [])
            .sorted { ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height) }
            .prefix(3)

        for face in observations {
            let bb = face.boundingBox
            let tlImg = CGPoint(x: bb.minX, y: 1.0 - bb.maxY)
            let brImg = CGPoint(x: bb.maxX, y: 1.0 - bb.minY)
            let p1 = imageTopLeftToStrip(tlImg)
            let p2 = imageTopLeftToStrip(brImg)
            let boxMinX = min(p1.x, p2.x)
            let boxMaxX = max(p1.x, p2.x)
            let boxMinY = min(p1.y, p2.y)
            let boxMaxY = max(p1.y, p2.y)
            let faceBoxStrip = CGRect(x: boxMinX, y: boxMinY, width: max(0.02, boxMaxX - boxMinX), height: max(0.02, boxMaxY - boxMinY))

            // Kiểm tra khuôn mặt nằm trong vùng hiển thị của ô
            guard faceBoxStrip.intersects(normSlotRect) else { continue }

            func regionCenterInStrip(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                guard let region, region.pointCount > 0 else { return nil }
                let pts = region.normalizedPoints
                var sx: CGFloat = 0
                var sy: CGFloat = 0
                for p in pts {
                    sx += p.x
                    sy += p.y
                }
                let nx = sx / CGFloat(pts.count)
                let ny = sy / CGFloat(pts.count)
                let imgX = bb.origin.x + nx * bb.size.width
                let imgY = 1.0 - (bb.origin.y + ny * bb.size.height)
                return imageTopLeftToStrip(CGPoint(x: imgX, y: imgY))
            }

            let rawEyeL = regionCenterInStrip(face.landmarks?.leftEye)
                ?? CGPoint(x: faceBoxStrip.minX + faceBoxStrip.width * 0.32, y: faceBoxStrip.minY + faceBoxStrip.height * 0.38)
            let rawEyeR = regionCenterInStrip(face.landmarks?.rightEye)
                ?? CGPoint(x: faceBoxStrip.minX + faceBoxStrip.width * 0.68, y: faceBoxStrip.minY + faceBoxStrip.height * 0.38)

            // Chuẩn hóa mắt trái/phải theo trục ngang hiển thị sau khi xét lật gương
            let eyeLeft = rawEyeL.x <= rawEyeR.x ? rawEyeL : rawEyeR
            let eyeRight = rawEyeL.x <= rawEyeR.x ? rawEyeR : rawEyeL

            // Tính góc nghiêng thực trong hệ pixel (nhân tỷ lệ canvasW/canvasH để tránh méo góc)
            let dxPx = (eyeRight.x - eyeLeft.x) * canvasW
            let dyPx = (eyeRight.y - eyeLeft.y) * canvasH
            let rollRad = atan2(dyPx, max(1.0, dxPx))
            let rollDeg = max(-36.0, min(36.0, Double(rollRad * 180.0 / .pi)))

            // Vector đơn vị sang phải & lên đỉnh đầu theo góc nghiêng đầu (tính trong không gian pixel rồi quy về [0,1])
            let faceWPx = faceBoxStrip.width * canvasW
            let faceHPx = faceBoxStrip.height * canvasH
            let rx = cos(rollRad)
            let ry = sin(rollRad)
            let ux = sin(rollRad)
            let uy = -cos(rollRad)

            func shiftFrom(_ base: CGPoint, rightUnits: CGFloat, upUnits: CGFloat) -> CGPoint {
                let bx = base.x * canvasW + rightUnits * rx + upUnits * ux
                let by = base.y * canvasH + rightUnits * ry + upUnits * uy
                let clampedX = max(normSlotRect.minX + normSlotRect.width * 0.06, min(normSlotRect.maxX - normSlotRect.width * 0.06, bx / canvasW))
                let clampedY = max(normSlotRect.minY + normSlotRect.height * 0.05, min(normSlotRect.maxY - normSlotRect.height * 0.05, by / canvasH))
                return CGPoint(x: clampedX, y: clampedY)
            }

            let eyeBridge = CGPoint(x: (eyeLeft.x + eyeRight.x) * 0.5, y: (eyeLeft.y + eyeRight.y) * 0.5)
            let headCrown = shiftFrom(eyeBridge, rightUnits: 0, upUnits: faceHPx * 0.72)
            let leftTemple = shiftFrom(eyeBridge, rightUnits: -faceWPx * 0.48, upUnits: faceHPx * 0.44)
            let rightTemple = shiftFrom(eyeBridge, rightUnits: faceWPx * 0.48, upUnits: faceHPx * 0.44)
            let leftCheek = shiftFrom(eyeBridge, rightUnits: -faceWPx * 0.36, upUnits: -faceHPx * 0.22)
            let rightCheek = shiftFrom(eyeBridge, rightUnits: faceWPx * 0.36, upUnits: -faceHPx * 0.22)
            let leftShoulder = shiftFrom(eyeBridge, rightUnits: -faceWPx * 0.82, upUnits: -faceHPx * 0.72)
            let rightShoulder = shiftFrom(eyeBridge, rightUnits: faceWPx * 0.82, upUnits: -faceHPx * 0.72)

            let spaceLeft = faceBoxStrip.minX - normSlotRect.minX
            let spaceRight = normSlotRect.maxX - faceBoxStrip.maxX

            detectedFaces.append(
                PhotoboothSlotSemanticMap.FaceAnchors(
                    faceBoxInStrip: faceBoxStrip,
                    headCrown: headCrown,
                    eyeBridge: eyeBridge,
                    leftTemple: leftTemple,
                    rightTemple: rightTemple,
                    leftCheek: leftCheek,
                    rightCheek: rightCheek,
                    leftShoulder: leftShoulder,
                    rightShoulder: rightShoulder,
                    faceWidthInStrip: faceBoxStrip.width,
                    rollDegrees: rollDeg,
                    openSideIsRight: spaceRight >= spaceLeft
                )
            )
        }

        // Chấm điểm 6 vùng góc trống / cạnh viền trong ô ảnh để các sticker trang trí TUYỆT ĐỐI tránh khuôn mặt
        let rawSlotCorners: [CGPoint] = [
            CGPoint(x: normSlotRect.minX + normSlotRect.width * 0.13, y: normSlotRect.minY + normSlotRect.height * 0.15),
            CGPoint(x: normSlotRect.maxX - normSlotRect.width * 0.13, y: normSlotRect.minY + normSlotRect.height * 0.15),
            CGPoint(x: normSlotRect.minX + normSlotRect.width * 0.14, y: normSlotRect.maxY - normSlotRect.height * 0.15),
            CGPoint(x: normSlotRect.maxX - normSlotRect.width * 0.14, y: normSlotRect.maxY - normSlotRect.height * 0.15),
            CGPoint(x: normSlotRect.midX, y: normSlotRect.minY + normSlotRect.height * 0.10),
            CGPoint(x: normSlotRect.midX, y: normSlotRect.maxY - normSlotRect.height * 0.10),
        ]

        let scoredCorners = rawSlotCorners.sorted { a, b in
            minDistanceToFaces(a, faces: detectedFaces) > minDistanceToFaces(b, faces: detectedFaces)
        }

        return PhotoboothSlotSemanticMap(
            slotIndex: slotIndex,
            slotRectInStrip: normSlotRect,
            faces: detectedFaces,
            safeCornersInStrip: scoredCorners
        )
    }

    private static func minDistanceToFaces(_ point: CGPoint, faces: [PhotoboothSlotSemanticMap.FaceAnchors]) -> CGFloat {
        guard !faces.isEmpty else { return 1.0 }
        var best: CGFloat = 10.0
        for f in faces {
            let box = f.faceBoxInStrip
            let cx = max(box.minX, min(point.x, box.maxX))
            let cy = max(box.minY, min(point.y, box.maxY))
            let d = hypot(point.x - cx, point.y - cy)
            if d < best { best = d }
        }
        return best
    }

    private static func overlapPenalty(at point: CGPoint, existing: [PlacedPhotoboothSticker]) -> Double {
        var penalty = 0.0
        for st in existing {
            let d = hypot(Double(point.x - st.normalizedX), Double(point.y - st.normalizedY))
            if d < 0.14 {
                penalty += (0.14 - d) / 0.14
            }
        }
        return penalty
    }

    private static func clampScale(_ value: CGFloat, min minV: CGFloat, max maxV: CGFloat) -> CGFloat {
        max(minV, min(maxV, value))
    }

    private static func fallbackCenterPoint(config: PhotoboothStripConfig) -> CGPoint {
        let size = config.layout.canvasSize
        if let first = config.layout.slotRects(in: size, marginScale: config.marginScale).first {
            return CGPoint(x: first.maxX / max(1, size.width) - 0.10, y: first.minY / max(1, size.height) + 0.08)
        }
        return CGPoint(x: 0.5, y: 0.5)
    }
}
