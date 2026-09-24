import XCTest
import AppKit
import CoreImage
import ImageIO
@testable import LumiBase

final class PhotoExportServiceTests: XCTestCase {
    
    func testExportBatchProgressFraction() {
        let p1 = ExportProgress(completed: 1, total: 4, currentFilename: "test1.arw", outputURL: nil)
        XCTAssertEqual(p1.fractionCompleted, 0.25)
        
        let p2 = ExportProgress(completed: 4, total: 4, currentFilename: "test4.arw", outputURL: nil)
        XCTAssertEqual(p2.fractionCompleted, 1.0)
        
        let p0 = ExportProgress(completed: 0, total: 0, currentFilename: "", outputURL: nil)
        XCTAssertEqual(p0.fractionCompleted, 0.0)
    }
    
    func testExportRasterImageToJPEG() throws {
        // Create a temporary test JPG
        let tempDir = inspectionTestScratchURL("LumiBaseExportTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceURL = tempDir.appendingPathComponent("sample.png")
        let destURL = tempDir.appendingPathComponent("sample_exported.jpg")
        
        // Generate a 200x200 bitmap
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 200,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 200 * 4,
            bitsPerPixel: 32
        )!
        let pngData = rep.representation(using: .png, properties: [:])!
        try pngData.write(to: sourceURL)
        
        var xmp = XMPMetadata()
        xmp.exposure2012 = 0.3
        xmp.highlights2012 = -20
        
        let asset = PhotoAsset(
            fileURL: sourceURL,
            fileSize: Int64(pngData.count),
            dateModified: Date(),
            dateCreated: Date(),
            xmp: xmp,
            cameraMetadata: CameraMetadata(make: "Sony", model: "ILCE-7CM2")
        )
        
        let exported = try PhotoExportService.shared.exportPhoto(asset: asset, to: destURL, quality: 0.95)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        
        // Validate image source and dimensions
        guard let source = CGImageSourceCreateWithURL(exported as CFURL, nil) else {
            XCTFail("Failed to read exported JPEG")
            return
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read exported JPEG properties")
            return
        }
        
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        XCTAssertEqual(width, 200)
        XCTAssertEqual(height, 200)
    }
    
    func testExportRealSonyA7C2RAWPhoto() throws {
        let rawURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00986.ARW")
        let xmpURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00986.xmp")
        
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            // Skip if volume is unmounted
            return
        }
        
        let tempDir = inspectionTestScratchURL("LumiBaseRealExportTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let destURL = tempDir.appendingPathComponent("A7C00986_exported.jpg")
        let xmp = XMPParser.parse(url: xmpURL)
        let cameraMeta = MetadataReader.readMetadata(from: rawURL).camera
        
        let asset = PhotoAsset(
            fileURL: rawURL,
            fileSize: 37_000_000,
            dateModified: Date(),
            dateCreated: Date(),
            xmp: xmp,
            cameraMetadata: cameraMeta
        )
        
        let exported = try PhotoExportService.shared.exportPhoto(asset: asset, to: destURL, quality: 0.95)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        
        guard let source = CGImageSourceCreateWithURL(exported as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            XCTFail("Failed to read exported real RAW JPEG")
            return
        }
        
        // Full Sony A7C II 33MP resolution check
        let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        XCTAssertGreaterThan(width, 7000, "Should be full resolution 7008 width")
        XCTAssertGreaterThan(height, 4600, "Should be full resolution 4672 height")
        
        // EXIF preservation check
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif, "EXIF dictionary must be preserved in exported JPEG")
        XCTAssertNotNil(tiff, "TIFF dictionary must be preserved in exported JPEG")
        
        if let tiffDict = tiff, let model = tiffDict[kCGImagePropertyTIFFModel as String] as? String {
            XCTAssertTrue(model.contains("ILCE-7CM2"), "Camera model ILCE-7CM2 must be preserved")
        } else {
            XCTFail("Missing TIFF model in exported JPEG")
        }
    }
    
    func testExportPortraitSonyRAWPhotoOrientation() throws {
        let rawURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C01319.ARW")
        let xmpURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C01319.xmp")
        
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            return
        }
        
        let tempDir = inspectionTestScratchURL("LumiBasePortraitExportTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let destURL = tempDir.appendingPathComponent("A7C01319_portrait.jpg")
        let xmp = XMPParser.parse(url: xmpURL)
        let cameraMeta = MetadataReader.readMetadata(from: rawURL).camera
        
        let asset = PhotoAsset(
            fileURL: rawURL,
            fileSize: 37_000_000,
            dateModified: Date(),
            dateCreated: Date(),
            xmp: xmp,
            cameraMetadata: cameraMeta
        )
        
        let exported = try PhotoExportService.shared.exportPhoto(asset: asset, to: destURL, quality: 0.95)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        
        guard let source = CGImageSourceCreateWithURL(exported as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            XCTFail("Failed to read exported portrait JPEG")
            return
        }
        
        let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        
        // Portrait check: Height must be greater than Width (7008 x 4672)
        XCTAssertGreaterThan(height, width, "Portrait photo must have height > width, got \(width)x\(height)")
        XCTAssertEqual(width, 4672, "Exported portrait width should be 4672")
        XCTAssertEqual(height, 7008, "Exported portrait height should be 7008")
        
        // Orientation tag must be 1 (Upright)
        let orientation = props[kCGImagePropertyOrientation as String] as? Int
        XCTAssertEqual(orientation, 1, "Orientation must be 1 so photo viewer doesn't double-rotate")
    }
    
    func testThumbnailPortraitRAWPhotoOrientation() async throws {
        let rawURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C01319.ARW")
        let xmpURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C01319.xmp")
        
        guard FileManager.default.fileExists(atPath: rawURL.path) else { return }
        
        let xmp = XMPParser.parse(url: xmpURL)
        let cameraMeta = MetadataReader.readMetadata(from: rawURL).camera
        
        let asset = PhotoAsset(
            fileURL: rawURL,
            fileSize: 37_000_000,
            dateModified: Date(),
            dateCreated: Date(),
            xmp: xmp,
            cameraMetadata: cameraMeta
        )
        
        let thumb = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 400)
        XCTAssertNotNil(thumb)
        if let thumb = thumb {
            print("Thumbnail size for A7C01319.ARW: \(thumb.size.width) x \(thumb.size.height)")
            XCTAssertGreaterThan(thumb.size.height, thumb.size.width, "RAW thumbnail must be portrait (height > width)")
        }
    }
    
    func testOldExportedJPEGThumbnail() async throws {
        let oldExportedURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/untitled folder/A7C01319.jpg")
        guard FileManager.default.fileExists(atPath: oldExportedURL.path) else { return }
        
        let asset = PhotoAsset(
            fileURL: oldExportedURL,
            fileSize: 11_000_000,
            dateModified: Date(),
            dateCreated: Date()
        )
        
        // Check ImageIO orientation on disk
        if let src = CGImageSourceCreateWithURL(oldExportedURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            print("Old A7C01319.jpg props: Orientation=\(props[kCGImagePropertyOrientation as String] ?? "nil")")
        }
        
        let thumb = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 400)
        if let thumb = thumb {
            print("Thumbnail size for old A7C01319.jpg: \(thumb.size.width) x \(thumb.size.height)")
        }
    }
}
