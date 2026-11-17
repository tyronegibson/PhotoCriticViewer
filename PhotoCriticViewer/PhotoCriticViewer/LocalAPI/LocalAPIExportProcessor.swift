import AppKit
import CoreGraphics
import Vision

/// Finishes an export_photo.py intermediate (a full-resolution, EXIF-handled JPEG) into the
/// final deliverable: subject-aware crop, resize, explicit sRGB, and an optional watermark.
/// This logic lives in Swift specifically because subject-aware cropping needs Apple's Vision
/// framework (face/person detection) -- there's no equivalent on the Python side of this
/// project, so that side only ever decodes the RAW and hands off a full-frame intermediate.
enum LocalAPIExportProcessor {
    struct Preset {
        /// nil = "original": no crop, native aspect kept.
        let ratio: (w: Double, h: Double)?
        let longEdge: Int
        let quality: Double
    }

    static let presets: [String: Preset] = [
        "instagram_4x5": Preset(ratio: (4, 5), longEdge: 2048, quality: 0.9),
        "instagram_square": Preset(ratio: (1, 1), longEdge: 2048, quality: 0.9),
        "instagram_story": Preset(ratio: (9, 16), longEdge: 2048, quality: 0.9),
        "original": Preset(ratio: nil, longEdge: 2048, quality: 0.9),
        // Model Mayhem's long-cited upload guidance: roughly 1000px on the long edge, well
        // under their file-size cap. This isn't pulled from a current official spec, so treat
        // it as a reasonable default to verify against MM's own upload page, not an exact
        // requirement -- see API.md.
        "modelmayhem": Preset(ratio: nil, longEdge: 1000, quality: 0.85),
    ]

    struct Options {
        var preset: String
        var longEdge: Int?
        var quality: Int?
        /// Normalized 0-1 center point override ({"x":, "y"}, top-left origin) -- when given,
        /// skips Vision detection entirely and centers the crop here instead.
        var cropOffset: CGPoint?
        var watermarkText: String?
    }

    enum ProcessorError: Error, LocalizedError {
        case unreadableIntermediate(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .unreadableIntermediate(let path): return "could not read intermediate image at \(path)"
            case .writeFailed(let path): return "could not write final image to \(path)"
            }
        }
    }

    /// Runs entirely synchronously (Vision's request handlers block) -- callers run this off
    /// the main actor, e.g. from within an async API handler already hopping work to a
    /// background context.
    static func finish(intermediatePath: String, options: Options, finalURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: intermediatePath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProcessorError.unreadableIntermediate(intermediatePath)
        }

        let preset = presets[options.preset] ?? presets["original"]!
        let longEdge = options.longEdge ?? preset.longEdge
        let quality = CGFloat(options.quality.map { Double($0) / 100 } ?? preset.quality)

        var working = image
        if let ratio = preset.ratio {
            let rect = cropRect(for: working, ratio: ratio, offset: options.cropOffset)
            if let cropped = working.cropping(to: rect) {
                working = cropped
            }
        }
        working = resized(working, longEdge: longEdge)
        working = srgb(working) ?? working
        if let text = options.watermarkText, !text.isEmpty {
            working = watermarked(working, text: text)
        }

        try write(working, to: finalURL, quality: quality)
        try? FileManager.default.removeItem(atPath: intermediatePath)
    }

    // MARK: - Subject-aware crop

    /// Centers the crop on an explicit offset override if given; otherwise on the largest
    /// detected face (expanded to an approximate head+shoulders region), then the largest
    /// detected person, then the image's own center -- then nudged so the detected subject
    /// box is never cut off, which is the specific failure a naive center crop has: a head or
    /// a hand right at the frame's edge gets sliced by an unaware crop.
    static func cropRect(for image: CGImage, ratio: (w: Double, h: Double), offset: CGPoint?) -> CGRect {
        let width = Double(image.width), height = Double(image.height)
        let targetAspect = ratio.w / ratio.h

        if let offset {
            return centeredCrop(imageWidth: width, imageHeight: height, aspect: targetAspect, centerX: offset.x, centerY: offset.y)
        }

        guard let subjectBox = detectSubjectBoundingBox(in: image) else {
            return centeredCrop(imageWidth: width, imageHeight: height, aspect: targetAspect, centerX: 0.5, centerY: 0.5)
        }
        // Vision's normalized rect has a bottom-left origin; centeredCrop/expandToContain
        // below both work in a top-left-origin pixel space, matching CGImage.cropping(to:).
        let centerX = subjectBox.midX
        let centerY = 1 - subjectBox.midY
        let initial = centeredCrop(imageWidth: width, imageHeight: height, aspect: targetAspect, centerX: centerX, centerY: centerY)
        return expandToContain(initial, subjectBox: subjectBox, imageWidth: width, imageHeight: height)
    }

    private static func detectSubjectBoundingBox(in image: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let faceRequest = VNDetectFaceRectanglesRequest()
        try? handler.perform([faceRequest])
        if let faces = faceRequest.results, !faces.isEmpty {
            let largest = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!
            let box = largest.boundingBox
            // Vision's face box is tight to the face itself; expand it into an approximate
            // head+shoulders region so the crop logic below has a sensible subject region to
            // protect, not just the face.
            let expandedHeight = box.height * 2.4
            let expandedWidth = box.width * 1.8
            let expanded = CGRect(
                x: box.midX - expandedWidth / 2, y: max(0, box.midY - expandedHeight * 0.65),
                width: expandedWidth, height: expandedHeight
            )
            return expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let personRequest = VNDetectHumanRectanglesRequest()
        try? handler.perform([personRequest])
        if let people = personRequest.results, !people.isEmpty {
            return people.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!.boundingBox
        }

        return nil
    }

    /// The largest `aspect`-ratio rect that fits inside an `imageWidth`x`imageHeight` image,
    /// centered as close to (centerX, centerY) (fractions of the image, top-left origin) as
    /// the image bounds allow.
    static func centeredCrop(imageWidth: Double, imageHeight: Double, aspect: Double, centerX: Double, centerY: Double) -> CGRect {
        let imageAspect = imageWidth / imageHeight
        let cropWidth: Double, cropHeight: Double
        if imageAspect > aspect {
            cropHeight = imageHeight
            cropWidth = cropHeight * aspect
        } else {
            cropWidth = imageWidth
            cropHeight = cropWidth / aspect
        }
        var x = centerX * imageWidth - cropWidth / 2
        var y = centerY * imageHeight - cropHeight / 2
        x = min(max(0, x), imageWidth - cropWidth)
        y = min(max(0, y), imageHeight - cropHeight)
        return CGRect(x: x, y: y, width: cropWidth, height: cropHeight)
    }

    /// Nudges `crop` toward a detected subject (normalized, bottom-left-origin `subjectBox`)
    /// if the centered crop doesn't already fully contain it -- can happen when the subject is
    /// near an edge and centeredCrop had to clamp. May still not fully contain a subject much
    /// wider/taller than the crop itself, but it will never do worse than a plain center crop.
    static func expandToContain(_ crop: CGRect, subjectBox: CGRect, imageWidth: Double, imageHeight: Double) -> CGRect {
        let subjectPixels = CGRect(
            x: subjectBox.minX * imageWidth, y: (1 - subjectBox.maxY) * imageHeight,
            width: subjectBox.width * imageWidth, height: subjectBox.height * imageHeight
        )
        var x = crop.minX, y = crop.minY
        if subjectPixels.minX < crop.minX { x = subjectPixels.minX }
        if subjectPixels.maxX > crop.maxX { x = subjectPixels.maxX - crop.width }
        if subjectPixels.minY < crop.minY { y = subjectPixels.minY }
        if subjectPixels.maxY > crop.maxY { y = subjectPixels.maxY - crop.height }
        x = min(max(0, x), imageWidth - crop.width)
        y = min(max(0, y), imageHeight - crop.height)
        return CGRect(x: x, y: y, width: crop.width, height: crop.height)
    }

    // MARK: - Resize / color / watermark / write

    static func resized(_ image: CGImage, longEdge: Int) -> CGImage {
        let width = image.width, height = image.height
        let currentLongEdge = max(width, height)
        guard currentLongEdge > longEdge, currentLongEdge > 0 else { return image }
        let scale = Double(longEdge) / Double(currentLongEdge)
        let newWidth = max(1, Int(Double(width) * scale))
        let newHeight = max(1, Int(Double(height) * scale))
        guard let colorSpace = image.colorSpace,
              let context = CGContext(
                data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
              ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    static func srgb(_ image: CGImage) -> CGImage? {
        guard let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return image.copy(colorSpace: srgbSpace)
    }

    static func watermarked(_ image: CGImage, text: String) -> CGImage {
        guard let colorSpace = image.colorSpace,
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
              ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let fontSize = CGFloat(image.height) * 0.025
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ]
        let line = NSAttributedString(string: text, attributes: attributes)
        let size = line.size()
        let margin = fontSize
        let origin = CGPoint(x: CGFloat(image.width) - size.width - margin, y: margin)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        line.draw(at: origin)
        NSGraphicsContext.current = previous

        return context.makeImage() ?? image
    }

    static func write(_ image: CGImage, to url: URL, quality: CGFloat) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw ProcessorError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessorError.writeFailed(url.path)
        }
    }
}
