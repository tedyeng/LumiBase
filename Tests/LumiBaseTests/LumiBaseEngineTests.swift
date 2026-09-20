import XCTest
import AppKit
@testable import LumiBase

final class LumiBaseEngineTests: XCTestCase {
    
    func testCameraMetadataFormatting() {
        let metadata = CameraMetadata(
            make: "SONY",
            model: "ILCE-7RM5",
            lensModel: "FE 35mm F1.4 GM",
            focalLength: 35.0,
            focalLength35mm: 35.0,
            aperture: 1.4,
            shutterSpeed: "1/500s",
            iso: 100
        )
        
        XCTAssertEqual(metadata.exposureSummary, "35 mm  •  ƒ/1.4  •  1/500s  •  ISO 100")
    }
    
    func testThumbnailCacheKeyGeneration() {
        let cache = ThumbnailCacheManager.shared
        let url1 = URL(fileURLWithPath: "/photos/a.arw")
        let url2 = URL(fileURLWithPath: "/photos/b.arw")
        let date = Date(timeIntervalSince1970: 1000)
        
        let key1 = cache.cacheKey(for: url1, maxPixelSize: 300, dateModified: date)
        let key2 = cache.cacheKey(for: url2, maxPixelSize: 300, dateModified: date)
        let key1Again = cache.cacheKey(for: url1, maxPixelSize: 300, dateModified: date)
        
        XCTAssertEqual(key1, key1Again)
        XCTAssertNotEqual(key1, key2)
    }
    
    func testHistogramComputation() async {
        // Create a 100x100 solid red test image
        let size = NSSize(width: 100, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        
        let histogram = await HistogramCalculator.computeHistogram(for: image)
        
        XCTAssertEqual(histogram.red.count, 256)
        XCTAssertEqual(histogram.green.count, 256)
        XCTAssertEqual(histogram.blue.count, 256)
        XCTAssertEqual(histogram.luminance.count, 256)
        
        // Red channel max bin should be near 255
        XCTAssertGreaterThan(histogram.red[255], 0.5)
    }
    
    func testSupportedFileTypes() {
        XCTAssertTrue(SupportedFileType(rawValue: "arw")?.isRaw == true)
        XCTAssertTrue(SupportedFileType(rawValue: "cr3")?.isRaw == true)
        XCTAssertTrue(SupportedFileType(rawValue: "nef")?.isRaw == true)
        XCTAssertTrue(SupportedFileType(rawValue: "dng")?.isRaw == true)
        XCTAssertTrue(SupportedFileType(rawValue: "raf")?.isRaw == true)
        XCTAssertTrue(SupportedFileType(rawValue: "jpg")?.isRaw == false)
        XCTAssertTrue(SupportedFileType(rawValue: "png")?.isRaw == false)
    }
    
    func testDCPProfileManagerNormalizationAndDiscovery() {
        let manager = DCPProfileManager.shared
        
        XCTAssertEqual(manager.normalizeCameraModel("ILCE-7CM2"), "Sony ILCE-7CM2")
        XCTAssertEqual(manager.normalizeCameraModel("ILCE-7M4"), "Sony ILCE-7M4")
        XCTAssertEqual(manager.normalizeCameraModel("EOS R5"), "Canon EOS R5")
        XCTAssertEqual(manager.normalizeCameraModel("Z 6"), "Nikon Z 6")
        
        // Check if local Adobe Standard DCP for Sony A7C II is located
        let profileURL = manager.locateDCPProfile(cameraModel: "ILCE-7CM2")
        XCTAssertNotNil(profileURL)
        XCTAssertTrue(profileURL?.path.contains("ILCE-7CM2") == true)
    }
    
    func testAdobeColorPipelineProcessing() {
        let pipeline = AdobeColorPipeline.shared
        let testImage = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        
        let xmp = XMPMetadata(
            exposure2012: 0.5,
            temperature: 6200,
            tint: 8,
            contrast2012: 15,
            highlights2012: -50,
            shadows2012: 25
        )
        
        let processed = pipeline.process(image: testImage, cameraModel: "ILCE-7CM2", xmp: xmp)
        XCTAssertNotNil(processed)
        XCTAssertEqual(processed.extent.width, 100)
    }
}
