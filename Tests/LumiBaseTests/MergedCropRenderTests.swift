import XCTest
import CoreImage
@testable import LumiBase

final class MergedCropRenderTests: XCTestCase {
    func testCommittedCropChangesRenderedRasterDimensions() throws {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let holder = BaseImageHolder(full: image, display: image, interactive: image,
            fullExtent: image.extent, displayExtent: image.extent, interactiveExtent: image.extent,
            baseTemperature: nil, baseTint: nil, baseExposure: nil, isRaw: false)
        var settings = XMPMetadata()
        settings.hasCrop = true
        settings.cropLeft = 0.25
        settings.cropRight = 0.75
        settings.cropTop = 0.25
        settings.cropBottom = 0.75
        let output = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseHolder: holder,
            cameraModel: nil, xmp: settings, interactive: false))
        let cg = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 200)
        XCTAssertEqual(cg.height, 150)
    }

    func testRotationAutoInnerBoundingBoxCrop() throws {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        var settings = XMPMetadata()
        settings.hasCrop = true
        settings.cropAngle = 5.0 // 5 degrees rotation without manual crop coordinates

        let croppedCI = AdobeColorPipeline.shared.applyCrop(image: image, xmp: settings)
        let extent = croppedCI.extent
        
        // Extent should be smaller than original 400x300 due to automatic inner bounding box
        XCTAssertLessThan(extent.width, 400)
        XCTAssertLessThan(extent.height, 300)
        XCTAssertGreaterThan(extent.width, 300)
        XCTAssertGreaterThan(extent.height, 200)
    }
}
