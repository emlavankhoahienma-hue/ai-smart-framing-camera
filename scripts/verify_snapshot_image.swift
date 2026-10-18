import AppKit
import AVFoundation

func containsHostMarker(_ image: CGImage) -> Bool {
    let bitmap = NSBitmapImageRep(cgImage: image)
    let width = min(bitmap.pixelsWide, 180)
    let height = min(bitmap.pixelsHigh, 480)
    guard width >= 24, height >= 24 else { return false }

    // The simulator-only host paints an 18-point solid magenta square. Requiring
    // a filled patch prevents a colorful home-screen icon or URL prompt from
    // satisfying the visual test when the app did not reach the foreground.
    for y in stride(from: 0, through: height - 18, by: 4) {
        for x in stride(from: 0, through: width - 18, by: 4) {
            var patchIsSolid = true
            for sampleY in stride(from: y, through: y + 15, by: 3) {
                for sampleX in stride(from: x, through: x + 15, by: 3) {
                    guard let color = bitmap.colorAt(x: sampleX, y: sampleY)?
                        .usingColorSpace(.deviceRGB),
                        color.redComponent > 0.75,
                        color.greenComponent < 0.25,
                        color.blueComponent > 0.75 else {
                        patchIsSolid = false
                        break
                    }
                }
                if !patchIsSolid { break }
            }
            if patchIsSolid { return true }
        }
    }
    return false
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "SnapshotValidation", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected image or movie and file path"])
    }
    let kind = CommandLine.arguments[1]
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let images: [CGImage]
    switch kind {
    case "image":
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)),
              let image = bitmap.cgImage else {
            throw NSError(domain: "SnapshotValidation", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot decode screenshot"])
        }
        images = [image]
    case "movie":
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        images = try [1.0, 5.0, 10.0].map { second in
            try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600),
                                      actualTime: nil)
        }
    default:
        throw NSError(domain: "SnapshotValidation", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown media kind"])
    }
    guard images.allSatisfy(containsHostMarker) else {
        throw NSError(domain: "SnapshotValidation", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Snapshot host is absent from the rendered screen"])
    }
    print("Verified snapshot host in \(images.count) rendered image(s): \(url.lastPathComponent)")
} catch {
    fputs("Snapshot validation failed: \(error)\n", stderr)
    exit(1)
}
