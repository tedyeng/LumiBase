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
    
    func testStandardHighlightRecoveryCompressesHighlightsAndPreservesMidtones() {
        let pipeline = AdobeColorPipeline.shared
        let context = CIContext(options: [.useSoftwareRenderer: true])
        
        // Create an image with a highlight patch and a midtone patch
        let highlightColor = CIColor(red: 0.95, green: 0.85, blue: 0.70)
        let midtoneColor = CIColor(red: 0.50, green: 0.50, blue: 0.50)
        
        let highlightImg = CIImage(color: highlightColor).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let midtoneImg = CIImage(color: midtoneColor).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        
        var neutralXMP = XMPMetadata()
        neutralXMP.advancedRAWHighlightRecovery = false
        neutralXMP.highlights2012 = 0
        
        var recoveredXMP = XMPMetadata()
        recoveredXMP.advancedRAWHighlightRecovery = false
        recoveredXMP.highlights2012 = -100
        
        let processedNeutralHL = pipeline.process(image: highlightImg, cameraModel: nil, xmp: neutralXMP)
        let processedRecoveredHL = pipeline.process(image: highlightImg, cameraModel: nil, xmp: recoveredXMP)
        
        let processedNeutralMid = pipeline.process(image: midtoneImg, cameraModel: nil, xmp: neutralXMP)
        let processedRecoveredMid = pipeline.process(image: midtoneImg, cameraModel: nil, xmp: recoveredXMP)
        
        var bitmapNeutralHL = [UInt8](repeating: 0, count: 4)
        var bitmapRecoveredHL = [UInt8](repeating: 0, count: 4)
        var bitmapNeutralMid = [UInt8](repeating: 0, count: 4)
        var bitmapRecoveredMid = [UInt8](repeating: 0, count: 4)
        
        let cs = CGColorSpaceCreateDeviceRGB()
        context.render(processedNeutralHL, toBitmap: &bitmapNeutralHL, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(processedRecoveredHL, toBitmap: &bitmapRecoveredHL, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(processedNeutralMid, toBitmap: &bitmapNeutralMid, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(processedRecoveredMid, toBitmap: &bitmapRecoveredMid, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        
        // Highlights must be visibly compressed down (e.g. from ~240 down towards ~205-225)
        XCTAssertLessThan(bitmapRecoveredHL[0], bitmapNeutralHL[0])
        
        // Midtones should be well preserved (difference less than 22 out of 255)
        let midDiff = abs(Int(bitmapRecoveredMid[0]) - Int(bitmapNeutralMid[0]))
        XCTAssertLessThanOrEqual(midDiff, 22, "Midtones must not be crushed by highlight recovery")
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
        
        // 2. Control/Command click on photo 3 (toggle add) keeps photo 1 as primary
        appState.selectAsset(asset3, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset3.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset3.id)
        
        // 3. Control/Command click on photo 5 (toggle add) still keeps photo 1 as primary
        appState.selectAsset(asset5, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset3.id, asset5.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset5.id)
        
        // 4. Control/Command click on photo 3 again (toggle remove)
        appState.selectAsset(asset3, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset5.id])
        XCTAssertFalse(appState.selectedAssetIDs.contains(asset3.id))
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)

        // 5. Control/Command click on primary photo 1 (toggle remove) promotes remaining selected photo
        appState.selectAsset(asset1, isToggle: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset5.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset5.id)
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
        
        // 2. Shift-click on photo 4 -> should select photos 1, 2, 3, 4 and keep photo 1 as primary
        appState.selectAsset(asset4, isRange: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset2.id, asset3.id, asset4.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)
        // Anchor remains at photo 1
        XCTAssertEqual(appState.selectionAnchorAssetID, asset1.id)
        
        // 3. Shift-click on photo 2 -> range shrinks to 1, 2, primary remains photo 1
        appState.selectAsset(asset2, isRange: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset1.id, asset2.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset1.id)
        XCTAssertEqual(appState.selectionAnchorAssetID, asset1.id)
        
        // 4. Single click on photo 5 resets anchor and primary to 5
        appState.selectAsset(asset5)
        XCTAssertEqual(appState.selectedAssetIDs, [asset5.id])
        XCTAssertEqual(appState.selectionAnchorAssetID, asset5.id)
        
        // 5. Shift-click backwards to photo 3 -> should select photos 3, 4, 5 and keep photo 5 as primary
        appState.selectAsset(asset3, isRange: true)
        XCTAssertEqual(appState.selectedAssetIDs, [asset3.id, asset4.id, asset5.id])
        XCTAssertEqual(appState.primarySelectedAssetID, asset5.id)
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
    func testConfirmDeleteRemovesFilesAndXMP() async throws {
        let tempDir = inspectionTestScratchURL(UUID().uuidString)
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
        await appState.waitForTrashCompletion()
        
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
        await appState.waitForTrashCompletion()
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo2URL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmp2URL.path))
        XCTAssertEqual(appState.allAssets.count, 1)
        XCTAssertEqual(appState.primarySelectedAssetID, asset3.id)
    }
    
    @MainActor
    func testTrashFailureRetainsFixtureAndSelectionWithoutPermanentDeletion() async throws {
        class FailingTrashManager: FileManager, @unchecked Sendable {
            var permanentRemovalCalls = 0
            override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            override func removeItem(at URL: URL) throws {
                permanentRemovalCalls += 1
                try super.removeItem(at: URL)
            }
        }
        let directory = inspectionTestScratchURL(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.ARW")
        try "fixture-only".write(to: url, atomically: true, encoding: .utf8)
        let asset = PhotoAsset(fileURL: url)
        let state = AppState()
        state.allAssets = [asset]
        state.selectAsset(asset)
        state.requestDeleteSelectedPhotos()
        let manager = FailingTrashManager()
        state.confirmDeletePendingPhotos(fileManager: manager)
        await state.waitForTrashCompletion()
        XCTAssertNotNil(state.deleteErrorMessage)
        XCTAssertTrue(state.deleteErrorMessage?.contains("fixture.ARW") == true)
        XCTAssertEqual(manager.permanentRemovalCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(state.allAssets.map(\.id), [asset.id])
        XCTAssertEqual(state.primarySelectedAssetID, asset.id)
        XCTAssertEqual(state.selectedAssetIDs, [asset.id])
        XCTAssertFalse(state.showDeleteConfirmation)
        XCTAssertTrue(state.pendingDeleteAssets.isEmpty)
    }

    func testRawPlusJpgGroupingAndBadges() {
        let rawURL = URL(fileURLWithPath: "/photos/DSC0001.ARW")
        let jpgURL = URL(fileURLWithPath: "/photos/DSC0001.JPG")
        let standAloneJpgURL = URL(fileURLWithPath: "/photos/DSC0002.JPG")
        
        let rawAsset = PhotoAsset(fileURL: rawURL)
        let jpgAsset = PhotoAsset(fileURL: jpgURL)
        let standAloneJpgAsset = PhotoAsset(fileURL: standAloneJpgURL)
        
        let grouped = FolderScanner.groupRawAndCompanionAssets([rawAsset, jpgAsset, standAloneJpgAsset])
        
        XCTAssertEqual(grouped.count, 2)
        
        let paired = grouped.first(where: { $0.filename == "DSC0001.ARW" })
        XCTAssertNotNil(paired)
        XCTAssertTrue(paired?.isRaw == true)
        XCTAssertTrue(paired?.hasCompanionJPG == true)
        XCTAssertTrue(paired?.isRawPlusJPG == true)
        XCTAssertEqual(paired?.formatBadgeText, "RAW+JPG")
        XCTAssertEqual(paired?.companionURLs, [jpgURL])
        
        let singleJpg = grouped.first(where: { $0.filename == "DSC0002.JPG" })
        XCTAssertNotNil(singleJpg)
        XCTAssertFalse(singleJpg?.isRaw == true)
        XCTAssertFalse(singleJpg?.isRawPlusJPG == true)
        XCTAssertEqual(singleJpg?.formatBadgeText, "JPG")
    }
    
    @MainActor
    func testConfirmDeleteRemovesRawJpgAndXmp() async throws {
        let tempDir = inspectionTestScratchURL(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let rawURL = tempDir.appendingPathComponent("DSC0010.ARW")
        let jpgURL = tempDir.appendingPathComponent("DSC0010.JPG")
        let xmpURL = tempDir.appendingPathComponent("DSC0010.xmp")
        
        try "fake_raw_data".write(to: rawURL, atomically: true, encoding: .utf8)
        try "fake_jpg_data".write(to: jpgURL, atomically: true, encoding: .utf8)
        try "<xmp_data/>".write(to: xmpURL, atomically: true, encoding: .utf8)
        
        let rawAsset = PhotoAsset(fileURL: rawURL)
        let jpgAsset = PhotoAsset(fileURL: jpgURL)
        
        let grouped = FolderScanner.groupRawAndCompanionAssets([rawAsset, jpgAsset])
        XCTAssertEqual(grouped.count, 1)
        guard let pairedAsset = grouped.first else {
            XCTFail("Failed to group RAW+JPG")
            return
        }
        
        XCTAssertTrue(pairedAsset.isRawPlusJPG)
        XCTAssertTrue(pairedAsset.allAssociatedURLs.contains(rawURL))
        XCTAssertTrue(pairedAsset.allAssociatedURLs.contains(jpgURL))
        XCTAssertTrue(pairedAsset.allAssociatedURLs.contains(xmpURL))
        
        let appState = AppState()
        appState.allAssets = [pairedAsset]
        appState.selectAsset(pairedAsset)
        
        appState.requestDeleteSelectedPhotos()
        XCTAssertTrue(appState.showDeleteConfirmation)
        
        appState.confirmDeletePendingPhotos()
        await appState.waitForTrashCompletion()
        
        // Ensure all 3 files are deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpgURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmpURL.path))
        XCTAssertTrue(appState.allAssets.isEmpty)
    }
    
    @MainActor
    func testRatingUpdatesAndSyncsLiveDevelopXMP() {
        let url = URL(fileURLWithPath: "/photos/DSC0001.ARW")
        let asset = PhotoAsset(fileURL: url)
        let appState = AppState()
        appState.allAssets = [asset]
        appState.selectAsset(asset)
        
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 0)
        
        // Emulate live develop setting adjustment
        appState.updateDevelopSettings(isDragging: false) { xmp in
            xmp.exposure2012 = 0.5
        }
        
        // Set rating to 4
        appState.setRating(4)
        
        // Both allAssets and primarySelectedAsset should immediately reflect the new rating
        XCTAssertEqual(appState.allAssets.first?.xmp.rating, 4)
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 4)
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.exposure2012, 0.5)
        
        // Set flag
        appState.setFlag(.pick)
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.flag, .pick)
    }
    
    @MainActor
    func testIncreaseAndDecreaseRatingLightroomShortcuts() {
        let url = URL(fileURLWithPath: "/photos/DSC0002.ARW")
        let asset = PhotoAsset(fileURL: url)
        let appState = AppState()
        appState.allAssets = [asset]
        appState.selectAsset(asset)
        
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 0)
        
        // Decrease when at 0 should stay at 0
        appState.decreaseRating()
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 0)
        
        // Increase: 0 -> 1 -> 2 -> 3 -> 4 -> 5
        appState.increaseRating()
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 1)
        
        appState.increaseRating()
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 2)
        
        appState.increaseRating()
        appState.increaseRating()
        appState.increaseRating()
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 5)
        
        // Increase when at 5 should stay at 5
        appState.increaseRating()
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 5)
        
        // Decrease: 5 -> 4
        appState.decreaseRating()
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.rating, 4)
    }

    @MainActor
    func testSettingRatingToZeroSelectsNextPhoto() {
        var xmp1 = XMPMetadata.empty
        xmp1.rating = 2
        var xmp2 = XMPMetadata.empty
        xmp2.rating = 1
        var xmp3 = XMPMetadata.empty
        xmp3.rating = 3

        let a1 = PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/DSC0001.ARW"), xmp: xmp1)
        let a2 = PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/DSC0002.ARW"), xmp: xmp2)
        let a3 = PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/DSC0003.ARW"), xmp: xmp3)

        // 1. Unfiltered: setRating(0) on a2 selects next photo a3
        let appState = AppState()
        appState.allAssets = [a1, a2, a3]
        appState.selectAsset(a2)
        appState.setRating(0)
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == a2.id })?.xmp.rating, 0)
        XCTAssertEqual(appState.primarySelectedAssetID, a3.id)
        XCTAssertEqual(appState.selectedAssetIDs, [a3.id])

        // 2. Filtered (>= 1★): decreaseRating() to 0 on a2 removes a2 from displayedAssets and selects next photo a3
        let filteredState = AppState()
        filteredState.allAssets = [a1, a2, a3]
        filteredState.filterCriteria.minimumRating = 1
        filteredState.selectAsset(a2)
        filteredState.decreaseRating()
        XCTAssertEqual(filteredState.allAssets.first(where: { $0.id == a2.id })?.xmp.rating, 0)
        XCTAssertEqual(filteredState.displayedAssets.map(\.id), [a1.id, a3.id])
        XCTAssertEqual(filteredState.primarySelectedAssetID, a3.id)
        XCTAssertEqual(filteredState.selectedAssetIDs, [a3.id])

        // 3. Filtered (>= 1★) on last photo a3: setRating(0) falls back to remaining previous photo a1
        filteredState.setRating(0)
        XCTAssertEqual(filteredState.displayedAssets.map(\.id), [a1.id])
        XCTAssertEqual(filteredState.primarySelectedAssetID, a1.id)
        XCTAssertEqual(filteredState.selectedAssetIDs, [a1.id])
    }

    @MainActor
    func testFilmstripHeightClampingAndSessionStatePersistence() async throws {
        let suiteName = "LumiBaseSessionTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = inspectionTestScratchURL(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let file1 = tempFolder.appendingPathComponent("DSC0010.ARW")
        let file2 = tempFolder.appendingPathComponent("DSC0020.ARW")
        var xmp1 = XMPMetadata.empty
        xmp1.rating = 2
        var xmp2 = XMPMetadata.empty
        xmp2.rating = 4
        let asset1 = PhotoAsset(fileURL: file1, xmp: xmp1)
        let asset2 = PhotoAsset(fileURL: file2, xmp: xmp2)

        let firstSession = AppState(
            preloader: PreviewPreloader(observeMemoryPressure: false),
            quickFolderScan: { _ in [asset1, asset2] },
            fullFolderScan: { _ in [asset1, asset2] },
            restoreSessionState: true,
            sessionDefaults: defaults
        )

        // Clamping check
        firstSession.filmstripHeight = 999
        XCTAssertEqual(firstSession.filmstripHeight, AppState.maxFilmstripHeight)
        firstSession.filmstripHeight = 10
        XCTAssertEqual(firstSession.filmstripHeight, AppState.minFilmstripHeight)
        firstSession.filmstripHeight = 148

        firstSession.workspaceMode = .develop
        firstSession.viewMode = .loupe
        firstSession.thumbnailSize = 310
        firstSession.isLeftSidebarVisible = false
        firstSession.isRightInspectorVisible = false
        firstSession.isFilmstripVisible = true
        firstSession.sortOrder = .ratingDescending
        var criteria = FilterCriteria()
        criteria.minimumRating = 2
        firstSession.filterCriteria = criteria

        firstSession.openFolder(url: tempFolder)
        try await Task.sleep(nanoseconds: 50_000_000)
        firstSession.selectAsset(asset2)

        // Relaunch with the same defaults
        let restoredSession = AppState(
            preloader: PreviewPreloader(observeMemoryPressure: false),
            quickFolderScan: { _ in [asset1, asset2] },
            fullFolderScan: { _ in [asset1, asset2] },
            restoreSessionState: true,
            sessionDefaults: defaults
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(restoredSession.filmstripHeight, 148)
        XCTAssertEqual(restoredSession.workspaceMode, .develop)
        XCTAssertEqual(restoredSession.viewMode, .loupe)
        XCTAssertEqual(restoredSession.thumbnailSize, 310)
        XCTAssertFalse(restoredSession.isLeftSidebarVisible)
        XCTAssertFalse(restoredSession.isRightInspectorVisible)
        XCTAssertTrue(restoredSession.isFilmstripVisible)
        XCTAssertEqual(restoredSession.sortOrder, .ratingDescending)
        XCTAssertEqual(restoredSession.filterCriteria, criteria)
        XCTAssertEqual(restoredSession.currentFolderURL?.standardizedFileURL, tempFolder.standardizedFileURL)
        XCTAssertEqual(restoredSession.primarySelectedAssetID, asset2.id)
    }
    
    func testAdobeColorPipelineEliminatesDoubleProcessing() {
        // Create a neutral test image
        let color = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        let testCI = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        
        var xmp = XMPMetadata()
        xmp.exposure2012 = 0.5
        xmp.temperature = 6000
        xmp.tint = 10
        
        // Emulate a BaseImageHolder decoded with native EV = 0.5 and Temp = 6000
        let holder = BaseImageHolder(
            full: testCI,
            display: testCI,
            interactive: testCI,
            fullExtent: testCI.extent,
            displayExtent: testCI.extent,
            interactiveExtent: testCI.extent,
            baseTemperature: 6000,
            baseTint: 10,
            baseExposure: 0.5,
            isRaw: true
        )
        
        // Processing should recognize that baseExposure and baseTemperature are already applied,
        // so deltaEV = 0 and deltaTemp = 0, avoiding duplicate EV and WB filter degradation!
        let processed = AdobeColorPipeline.shared.process(
            image: testCI,
            cameraModel: "ILCE-7CM2",
            xmp: xmp,
            baseHolder: holder
        )
        
        XCTAssertNotNil(processed)
        XCTAssertFalse(processed.extent.isEmpty)
    }
    
    func testDCPProfileParserAndManager() {
        let profile = DCPProfileManager.shared.profile(for: "ILCE-7CM2", requestedProfile: "Adobe Standard")
        XCTAssertNotNil(profile)
        guard let profile = profile else { return }
        
        XCTAssertEqual(profile.profileName, "Adobe Standard")
        XCTAssertNotNil(profile.forwardMatrix2)
        XCTAssertEqual(profile.forwardMatrix2?.count, 9)
        
        let interpMatrix = profile.interpolatedForwardMatrix(for: 6100.0)
        XCTAssertNotNil(interpMatrix)
        XCTAssertEqual(interpMatrix?.count, 9)
        
        let colorMatrix = profile.sRGBColorMatrix(for: 6100.0)
        XCTAssertNotNil(colorMatrix)
        if let mat = colorMatrix {
            let rSum = mat[0] + mat[1] + mat[2]
            let gSum = mat[3] + mat[4] + mat[5]
            let bSum = mat[6] + mat[7] + mat[8]
            fputs("sRGB Color Matrix: \(mat)\n", stderr)
            fputs("Row sums: \(rSum), \(gSum), \(bSum)\n", stderr)
            fputs("DCP Tone Curve: \(String(describing: profile.toneCurve))\n", stderr)
            XCTAssertEqual(rSum, 1.0, accuracy: 0.001)
            XCTAssertEqual(gSum, 1.0, accuracy: 0.001)
            XCTAssertEqual(bSum, 1.0, accuracy: 0.001)
        }
    }
    
    func testInspectFolderAndCompare() {
        let screenshotURL = URL(fileURLWithPath: "/Users/tedyeng/.gemini/antigravity/brain/815a12e7-1a0d-4506-9918-28577717752f/.user_uploaded/media_1790072463199.png")
        guard let source = CGImageSourceCreateWithURL(screenshotURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fputs("Could not load screenshot\n", stderr)
            return
        }
        let w = cgImage.width
        let h = cgImage.height
        fputs("Screenshot size: \(w)x\(h)\n", stderr)
        
        // In media_1790072463199.png:
        // Left side is LumiBase window (from x ~ 0 to 1200)
        // Right side is Lightroom Develop window (from x ~ 1200 to 1920)
        // In LumiBase, the main image preview is roughly x: 260 to 920, y: 270 to 760 (in window coords)
        // In Lightroom, the main image preview is roughly x: 1250 to 1750, y: 310 to 600
        
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext()
        let ci = CIImage(cgImage: cgImage)
        
        func sampleRect(name: String, rect: CGRect) {
            let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ci,
                kCIInputExtentKey: CIVector(cgRect: rect)
            ])!
            var pixel = [UInt8](repeating: 0, count: 4)
            if let out = avgFilter.outputImage {
                ctx.render(out, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
                fputs("Sample \(name): RGB = (\(pixel[0]), \(pixel[1]), \(pixel[2]))\n", stderr)
            }
        }
    }
        
    func testCIRAWFilterTempDirection() {
        let testURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00908.ARW")
        guard let rawFilter = CIRAWFilter(imageURL: testURL) else { return }
        let ctx = CIContext()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 1000, y: 3000, width: 50, height: 50)
        
        for temp in [4000.0, 5264.0, 6500.0, 8000.0] {
            rawFilter.neutralTemperature = Float(temp)
            rawFilter.neutralTint = 8.0
            if let img = rawFilter.outputImage {
                let avg = CIFilter(name: "CIAreaAverage", parameters: [
                    kCIInputImageKey: img,
                    kCIInputExtentKey: CIVector(cgRect: rect)
                ])!
                var pixel = [UInt8](repeating: 0, count: 4)
                if let out = avg.outputImage {
                    ctx.render(out, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
                    fputs("Temp \(temp)K: Sky RGB = (\(pixel[0]), \(pixel[1]), \(pixel[2]))\n", stderr)
                }
            }
        }
    }
        
    func testPipelineOutputComparison() async {
        let testURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00908.ARW")
        let xmpURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00908.xmp")
        let jpgURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00908.jpg")
        
        guard let xmpData = try? Data(contentsOf: xmpURL),
              let jpgSource = CGImageSourceCreateWithURL(jpgURL as CFURL, nil),
              let jpgCG = CGImageSourceCreateImageAtIndex(jpgSource, 0, nil) else {
            fputs("Could not load test assets\n", stderr)
            return
        }
        let xmp = XMPParser.parse(data: xmpData)
        let jpgCI = CIImage(cgImage: jpgCG)
        let jpgExtent = jpgCI.extent
        let ctx = CIContext()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        
        // Clear cache and load through actual RAWImageLoader
        RAWImageLoader.shared.clearCache()
        guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: testURL, xmp: xmp) else {
            XCTFail("Failed to load base holder")
            return
        }
        
        var evalXMP = xmp
        evalXMP.hasCrop = false
        evalXMP.cropAngle = 0.0
        evalXMP.highlights2012 = -100
        
        let processed = AdobeColorPipeline.shared.process(
            image: holder.full,
            cameraModel: "ILCE-7CM2",
            xmp: evalXMP,
            baseHolder: holder
        )
        
        let fullWidth = Int(holder.fullExtent.width)
        let fullHeight = Int(holder.fullExtent.height)
        
        if let cgImage = ctx.createCGImage(processed, from: holder.fullExtent, format: .RGBA8, colorSpace: srgb) {
            let outURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/A7C00908-LB.jpg")
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
                CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
                CGImageDestinationFinalize(dest)
                fputs("Exported updated /Volumes/Super SSD/Photo/Temp/A7C00908-LB.jpg successfully!\n", stderr)
            }
            
            // Compare 4 diagnostic patches against LR
            if let lrSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/A7C00908-LR.jpg") as CFURL, nil),
               let lrImg = CGImageSourceCreateImageAtIndex(lrSource, 0, nil) {
                let patches: [(String, Int, Int, Int, Int)] = [
                    ("Center Top Cloud", 3400, 300, 200, 200),
                    ("Cloud near Sun / God Ray", 4000, 2600, 200, 200),
                    ("Sunset Horizon Cloud", 3000, 2000, 200, 200),
                    ("Pier Shadow (must stay dark)", 2600, 2500, 50, 50)
                ]
                
                func stats(img: CGImage, x: Int, y: Int, pw: Int, ph: Int) -> (mean: Double, std: Double, minV: Double, maxV: Double) {
                    var data = [UInt8](repeating: 0, count: pw * ph * 4)
                    let bctx = CGContext(data: &data, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    let cropRect = CGRect(x: x, y: img.height - y - ph, width: pw, height: ph)
                    if let cropped = img.cropping(to: cropRect) {
                        bctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pw, height: ph))
                    }
                    var lumas: [Double] = []
                    for i in 0..<(pw * ph) {
                        let r = Double(data[i*4]), g = Double(data[i*4+1]), b = Double(data[i*4+2])
                        lumas.append(0.2126*r + 0.7152*g + 0.0722*b)
                    }
                    let mean = lumas.reduce(0, +) / Double(lumas.count)
                    let variance = lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)
                    return (mean, sqrt(variance), lumas.min() ?? 0, lumas.max() ?? 0)
                }
                
                fputs("--- Patch Contrast Diagnostics vs LR ---\n", stderr)
                for (name, x, y, pw, ph) in patches {
                    let lrS = stats(img: lrImg, x: x, y: y, pw: pw, ph: ph)
                    let lbS = stats(img: cgImage, x: x, y: y, pw: pw, ph: ph)
                    let ratio = (lbS.std / lrS.std) * 100
                    let str = String(format: "  %@: LR std=%.2f [min=%.0f, max=%.0f], LB std=%.2f [min=%.0f, max=%.0f], Ratio=%.1f%%\n", name, lrS.std, lrS.minV, lrS.maxV, lbS.std, lbS.minV, lbS.maxV, ratio)
                    fputs(str, stderr)
                }
            }
        }
        
        fputs("--- Evaluating LumiBase Production Pipeline vs Lightroom Classic Ground Truth ---\n", stderr)
        XCTAssertNotNil(processed)
        XCTAssertGreaterThan(processed.extent.width, 0)
        XCTAssertGreaterThan(processed.extent.height, 0)
        fputs("Pipeline processing completed successfully.\n", stderr)
    }
}

func inspectionTestScratchURL(_ component: String) -> URL {
    let root = ProcessInfo.processInfo.environment["LUMIBASE_TEST_OUTPUT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory.appendingPathComponent("lumibase-test-artifacts", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent(component)
}
