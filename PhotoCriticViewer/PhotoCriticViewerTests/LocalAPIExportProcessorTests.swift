import Testing
import CoreGraphics
@testable import PhotoCriticViewer

/// The subject-aware crop math (LocalAPIExportProcessor), tested at the geometry level without
/// needing a real image or Vision detection -- centeredCrop/expandToContain are the pure
/// functions the actual Vision-driven crop decision is built on.
struct LocalAPIExportProcessorTests {
    @Test func centeredCropOnASquareTargetFromAWideImageCropsWidthNotHeight() {
        let crop = LocalAPIExportProcessor.centeredCrop(imageWidth: 4000, imageHeight: 2000, aspect: 1, centerX: 0.5, centerY: 0.5)
        #expect(crop.height == 2000)
        #expect(crop.width == 2000)
    }

    @Test func centeredCropOnASquareTargetFromATallImageCropsHeightNotWidth() {
        let crop = LocalAPIExportProcessor.centeredCrop(imageWidth: 2000, imageHeight: 4000, aspect: 1, centerX: 0.5, centerY: 0.5)
        #expect(crop.width == 2000)
        #expect(crop.height == 2000)
    }

    @Test func centeredCropClampsToImageBoundsRatherThanGoingNegative() {
        // centerX near the left edge would put a 2000-wide crop's origin well below 0 if unclamped.
        let crop = LocalAPIExportProcessor.centeredCrop(imageWidth: 4000, imageHeight: 2000, aspect: 1, centerX: 0.02, centerY: 0.5)
        #expect(crop.minX >= 0)
        #expect(crop.maxX <= 4000)
    }

    @Test func fourByFivePresetRatioIsRespected() {
        let crop = LocalAPIExportProcessor.centeredCrop(imageWidth: 5000, imageHeight: 5000, aspect: 4.0 / 5.0, centerX: 0.5, centerY: 0.5)
        #expect(abs(crop.width / crop.height - 4.0 / 5.0) < 0.001)
    }

    @Test func expandToContainLeavesAnAlreadyContainingCropUntouched() {
        let crop = CGRect(x: 1000, y: 1000, width: 2000, height: 2000)
        // Subject box (normalized, bottom-left origin) safely inside the crop's pixel region.
        let subjectBox = CGRect(x: 0.3, y: 0.55, width: 0.1, height: 0.1) // pixel y = (1-0.65)*4000..(1-0.55)*4000 = 1400..1800
        let expanded = LocalAPIExportProcessor.expandToContain(crop, subjectBox: subjectBox, imageWidth: 4000, imageHeight: 4000)
        #expect(expanded == crop)
    }

    @Test func expandToContainNudgesTheCropTowardAnEdgeSubjectInsteadOfCuttingItOff() {
        // A subject near the top edge that a naive center crop would clip -- maxY = 0.98,
        // safely within Vision's valid normalized [0,1] range (unlike a maxY > 1, which could
        // never come from a real detection and made an earlier version of this test bogus).
        let crop = CGRect(x: 0, y: 1000, width: 2000, height: 2000) // covers pixel rows 1000-3000
        let subjectBox = CGRect(x: 0.4, y: 0.9, width: 0.1, height: 0.08) // pixel y = (1-0.98)*4000..(1-0.9)*4000 = 80..400, OUTSIDE the crop (above it)
        let expanded = LocalAPIExportProcessor.expandToContain(crop, subjectBox: subjectBox, imageWidth: 4000, imageHeight: 4000)
        let subjectPixelMinY = (1 - subjectBox.maxY) * 4000
        #expect(expanded.minY <= subjectPixelMinY)
    }

    @Test func expandToContainNeverExceedsImageBounds() {
        let crop = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let subjectBox = CGRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3) // partially outside the image itself
        let expanded = LocalAPIExportProcessor.expandToContain(crop, subjectBox: subjectBox, imageWidth: 4000, imageHeight: 4000)
        #expect(expanded.minX >= 0 && expanded.minY >= 0)
        #expect(expanded.maxX <= 4000 && expanded.maxY <= 4000)
    }

    private func makeTestImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func resizeLeavesAnImageSmallerThanTheTargetUntouched() {
        let image = makeTestImage(width: 200, height: 100)
        let result = LocalAPIExportProcessor.resized(image, longEdge: 400)
        #expect(result.width == 200 && result.height == 100)
    }

    @Test func resizeScalesDownPreservingAspectRatio() {
        let image = makeTestImage(width: 4000, height: 2000) // 2:1
        let result = LocalAPIExportProcessor.resized(image, longEdge: 1000)
        #expect(result.width == 1000)
        #expect(result.height == 500)
    }

    @Test func srgbConversionProducesAnSRGBColorSpace() {
        let image = makeTestImage(width: 10, height: 10)
        let converted = LocalAPIExportProcessor.srgb(image)
        #expect(converted?.colorSpace?.name == CGColorSpace.sRGB)
    }
}
