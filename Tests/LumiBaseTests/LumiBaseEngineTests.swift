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
    
    @MainActor
    func testSelectAllAndSelectedAssets() {
        let appState = AppState()
        let asset1 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo1.arw"))
        let asset2 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo2.arw"))
        let asset3 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo3.arw"))
        
        appState.allAssets = [asset1, asset2, asset3]
        XCTAssertEqual(appState.displayedAssets.count, 3)
        XCTAssertEqual(appState.selectedAssets.count, 0)
        
        // Select All (Command+A simulation)
        appState.selectAll()
        XCTAssertEqual(appState.selectedAssetIDs.count, 3)
        XCTAssertEqual(appState.selectedAssets.count, 3)
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)
        
        // Deselect All (Command+D simulation)
        appState.deselectAll()
        XCTAssertEqual(appState.selectedAssetIDs.count, 0)
        XCTAssertEqual(appState.selectedAssets.count, 0)
        XCTAssertNil(appState.primarySelectedAssetID)
    }
    
    @MainActor
    func testControlMultiSelectToggle() {
        let appState = AppState()
        let asset1 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo1.arw"))
        let asset2 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo2.arw"))
        let asset3 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo3.arw"))
        let asset4 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo4.arw"))
        let asset5 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo5.arw"))
        
        appState.allAssets = [asset1, asset2, asset3, asset4, asset5]
        
        // 1. Single click on photo 1
        appState.selectAsset(asset1)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset1.id)
        
        // 2. Control/Command click on photo 3 (toggle add)
        appState.selectAsset(asset3, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset3.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset3.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset3.id)
        
        // 3. Control/Command click on photo 5 (toggle add)
        appState.selectAsset(asset5, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset3.id, asset5.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset5.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset5.id)
        
        // 4. Control/Command click on photo 3 again (toggle remove)
        appState.selectAsset(asset3, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset5.id])
        XCTAssertFalse(appState.selectedAssetIDs.contains(asset3.id))
    }
    
    @MainActor
    func testShiftRangeSelection() {
        let appState = AppState()
        let asset1 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo1.arw"))
        let asset2 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo2.arw"))
        let asset3 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo3.arw"))
        let asset4 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo4.arw"))
        let asset5 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo5.arw"))
        
        appState.allAssets = [asset1, asset2, asset3, asset4, asset5]
        
        // 1. Click on photo 1 as anchor
        appState.selectAsset(asset1)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id])
        XCTAssertEqual(appState.selectionAnchorAssetID, asset1.id)
        
        // 2. Shift-click on photo 4 -> should select photos 1, 2, 3, 4
        appState.selectAsset(asset4, isRange: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset2.id, asset3.id, asset4.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset4.id)
        // Anchor remains at photo 1
        XCTAssertEqual(appState.selectionAnchorAssetID, asset1.id)
        
        // 3. Shift-click on photo 2 -> range shrinks to 1, 2
        appState.selectAsset(asset2, isRange: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset2.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset2.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset1.id)
        
        // 4. Single click on photo 5 resets anchor to 5
        appState.selectAsset(asset5)
        XCTAssertEqual(appState.selectedAssetIDs, [asset5.id])
        XCTAssertEqual(appState.selectionAnchorAssetID, asset5.id)
        
        // 5. Shift-click backwards to photo 3 -> should select photos 3, 4, 5
        appState.selectAsset(asset3, isRange: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset3.id, asset4.id, asset5.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset3.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset5.id)
    }
    
    @MainActor
    func testRequestDeletePopulatesPendingAssets() {
        let appState = AppState()
        let asset1 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo1.arw"))
        let asset2 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/photo2.arw"))
        appState.allAssets = [asset1, asset2]
        
        // Single select
        appState.selectAsset(asset1)
        appState.requestDeleteSelectedPhotos()
        XCTAssertTrue(appState.showDeleteConfirmation)
        XCTAssertEqual(appState.pendingDeleteAssets.map { $0.id }, [asset1.id])
        
        // Cancel
        appState.cancelDelete()
        XCTAssertFalse(appState.showDeleteConfirmation)
        XCTAssertTrue(appState.pendingDeleteAssets.isEmpty)
        
        // Multi select
        appState.selectAsset(asset2, isToggle: true)
        appState.requestDeleteSelectedPhotos()
        XCTAssertTrue(appState.showDeleteConfirmation)
        XCTAssertEqual(appState.pendingDeleteAssets.count, 2)
    }
    
    @MainActor
    func testConfirmDeleteRemovesFilesAndXMP() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Create 3 temporary photo files with XMP sidecars
        let photo1URL = tempDir.appendingPathComponent("DSC001.ARW")
        let xmp1URL = tempDir.appendingPathComponent("DSC001.ARW.xmp")
        let photo2URL = tempDir.appendingPathComponent("DSC002.ARW")
        let xmp2URL = tempDir.appendingPathComponent("DSC002.xmp")
        let photo3URL = tempDir.appendingPathComponent("DSC003.ARW")
        
        try "raw1".write(to: photo1URL, atomically: true, encoding: .utf8)
        try "<xmp1/>".write(to: xmp1URL, atomically: true, encoding: .utf8)
        try "raw2".write(to: photo2URL, atomically: true, encoding: .utf8)
        try "<xmp2/>".write(to: xmp2URL, atomically: true, encoding: .utf8)
        try "raw3".write(to: photo3URL, atomically: true, encoding: .utf8)
        
        let asset1 = PhotoAsset(fileURL: photo1URL)
        let asset2 = PhotoAsset(fileURL: photo2URL)
        let asset3 = PhotoAsset(fileURL: photo3URL)
        
        XCTAssertTrue(asset1.hasSidecarXMP)
        XCTAssertTrue(asset2.hasSidecarXMP)
        XCTAssertFalse(asset3.hasSidecarXMP)
        
        let appState = AppState()
        appState.allAssets = [asset1, asset2, asset3]
        appState.selectAsset(asset1)
        
        // Request delete asset1
        appState.requestDeleteSelectedPhotos()
        XCTAssertTrue(appState.showDeleteConfirmation)
        
        // Confirm delete
        appState.confirmDeletePendingPhotos()
        
        // Assert files removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo1URL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmp1URL.path))
        
        // Assert asset list updated & selection advanced to asset2
        XCTAssertEqual(appState.allAssets.count, 2)
        XCTAssertFalse(appState.allAssets.contains(where: { $0.id == asset1.id }))
        XCTAssertEqual(appState.primarySelectedAssetID, asset2.id)
        XCTAssertEqual(appState.selectedAssetIDs, [asset2.id])
        XCTAssertFalse(appState.showDeleteConfirmation)
        
        // Now delete asset2 (which has basename xmp)
        appState.requestDeleteSelectedPhotos()
        appState.confirmDeletePendingPhotos()
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo2URL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmp2URL.path))
        XCTAssertEqual(appState.allAssets.count, 1)
        XCTAssertEqual(appState.primarySelectedAssetID, asset3.id)
    }
}


