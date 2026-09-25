import XCTest
@testable import LumiBase

@MainActor
final class DevelopSyncTests: XCTestCase {
    
    // MARK: - Helper Asset Builder
    
    private func makeTestAsset(filename: String, xmp: XMPMetadata = .empty) -> PhotoAsset {
        let dummyURL = URL(fileURLWithPath: "/tmp/\(filename)")
        return PhotoAsset(
            fileURL: dummyURL,
            fileSize: 1024,
            dateModified: Date(),
            dateCreated: Date(),
            xmp: xmp,
            cameraMetadata: .empty
        )
    }
    
    // MARK: - 1. DevelopSyncOptions Tests
    
    func testSyncOptionsSelectivity() {
        var source = XMPMetadata.empty
        source.exposure2012 = 1.25
        source.contrast2012 = 25
        source.temperature = 5600
        source.tint = 12
        source.clarity2012 = 30
        source.cameraProfile = "Adobe Portrait"
        
        var target = XMPMetadata.empty
        target.exposure2012 = -0.5
        target.contrast2012 = 0
        target.temperature = 4200
        target.tint = 0
        target.clarity2012 = 0
        target.cameraProfile = "Adobe Standard"
        
        // Only sync Basic Tone (exposure, contrast, etc.) but NOT white balance or presence
        var options = DevelopSyncOptions()
        options.whiteBalance = false
        options.setAllPresence(false)
        options.cameraProfile = false
        
        options.apply(from: source, to: &target)
        
        // Tone should be updated
        XCTAssertEqual(target.exposure2012, 1.25)
        XCTAssertEqual(target.contrast2012, 25)
        
        // White balance and presence and profile should remain untouched
        XCTAssertEqual(target.temperature, 4200)
        XCTAssertEqual(target.tint, 0)
        XCTAssertEqual(target.clarity2012, 0)
        XCTAssertEqual(target.cameraProfile, "Adobe Standard")
    }
    
    func testSyncOptionsCheckAllAndCheckNone() {
        var options = DevelopSyncOptions()
        options.checkNone()
        XCTAssertFalse(options.hasAnySelected)
        XCTAssertFalse(options.exposure)
        XCTAssertFalse(options.whiteBalance)
        XCTAssertFalse(options.texture)
        
        options.checkAll(includeCrop: true)
        XCTAssertTrue(options.hasAnySelected)
        XCTAssertTrue(options.exposure)
        XCTAssertTrue(options.whiteBalance)
        XCTAssertTrue(options.crop)
    }
    
    func testSyncOptionsCheckModifiedOnly() {
        var source = XMPMetadata.empty
        source.exposure2012 = 0.75
        source.highlights2012 = -40
        source.temperature = nil // not modified
        source.tint = nil
        source.saturation = 20
        
        var options = DevelopSyncOptions()
        options.checkModified(from: source)
        
        XCTAssertTrue(options.exposure)
        XCTAssertTrue(options.highlights)
        XCTAssertTrue(options.saturation)
        XCTAssertFalse(options.whiteBalance)
        XCTAssertFalse(options.contrast)
        XCTAssertFalse(options.crop)
    }
    
    // MARK: - 2. Batch Synchronize Develop Settings Tests
    
    func testSyncDevelopSettingsAcrossSelectedPhotos() {
        let appState = AppState()
        
        var sourceXMP = XMPMetadata.empty
        sourceXMP.exposure2012 = 1.50
        sourceXMP.contrast2012 = 30
        sourceXMP.temperature = 6000
        sourceXMP.tint = 8
        sourceXMP.vibrance = 25
        
        let assetA = makeTestAsset(filename: "photoA.arw", xmp: sourceXMP)
        let assetB = makeTestAsset(filename: "photoB.arw")
        let assetC = makeTestAsset(filename: "photoC.arw")
        let assetD = makeTestAsset(filename: "photoD.arw") // Not selected
        
        appState.allAssets = [assetA, assetB, assetC, assetD]
        appState.selectedAssetIDs = [assetA.id, assetB.id, assetC.id]
        appState.primarySelectedAssetID = assetA.id
        
        var syncOptions = DevelopSyncOptions()
        syncOptions.whiteBalance = true
        syncOptions.setAllTone(true)
        syncOptions.setAllPresence(false) // Don't sync presence
        
        appState.syncDevelopSettings(options: syncOptions)
        
        // Check photoB
        let updatedB = appState.allAssets.first(where: { $0.id == assetB.id })?.xmp
        XCTAssertEqual(updatedB?.exposure2012, 1.50)
        XCTAssertEqual(updatedB?.contrast2012, 30)
        XCTAssertEqual(updatedB?.temperature, 6000)
        XCTAssertEqual(updatedB?.tint, 8)
        XCTAssertNil(updatedB?.vibrance) // Unsynced presence should remain nil
        
        // Check photoC
        let updatedC = appState.allAssets.first(where: { $0.id == assetC.id })?.xmp
        XCTAssertEqual(updatedC?.exposure2012, 1.50)
        XCTAssertEqual(updatedC?.temperature, 6000)
        
        // Check photoD (Unselected photo should not be modified)
        let updatedD = appState.allAssets.first(where: { $0.id == assetD.id })?.xmp
        XCTAssertNil(updatedD?.exposure2012)
        XCTAssertNil(updatedD?.temperature)
    }
    
    // MARK: - 3. Copy & Paste Develop Settings Tests
    
    func testCopyAndPasteDevelopSettings() {
        let appState = AppState()
        
        var sourceXMP = XMPMetadata.empty
        sourceXMP.exposure2012 = -0.85
        sourceXMP.highlights2012 = -50
        sourceXMP.shadows2012 = 40
        sourceXMP.clarity2012 = 18
        
        let asset1 = makeTestAsset(filename: "1.arw", xmp: sourceXMP)
        let asset2 = makeTestAsset(filename: "2.arw")
        let asset3 = makeTestAsset(filename: "3.arw")
        
        appState.allAssets = [asset1, asset2, asset3]
        appState.primarySelectedAssetID = asset1.id
        appState.selectedAssetIDs = [asset1.id]
        
        // 1. Copy Settings with only Basic Tone
        var copyOpts = DevelopSyncOptions()
        copyOpts.setAllTone(true)
        copyOpts.setAllPresence(false)
        appState.copyDevelopSettings(from: asset1.id, options: copyOpts)
        
        XCTAssertNotNil(appState.copiedDevelopSettings)
        XCTAssertEqual(appState.copiedDevelopSettings?.exposure2012, -0.85)
        
        // 2. Select asset2 & asset3 and Paste
        appState.selectedAssetIDs = [asset2.id, asset3.id]
        appState.primarySelectedAssetID = asset2.id
        appState.pasteDevelopSettings()
        
        let updated2 = appState.allAssets.first(where: { $0.id == asset2.id })?.xmp
        XCTAssertEqual(updated2?.exposure2012, -0.85)
        XCTAssertEqual(updated2?.highlights2012, -50)
        XCTAssertEqual(updated2?.shadows2012, 40)
        XCTAssertNil(updated2?.clarity2012) // presence wasn't copied
        
        let updated3 = appState.allAssets.first(where: { $0.id == asset3.id })?.xmp
        XCTAssertEqual(updated3?.exposure2012, -0.85)
    }
    
    // MARK: - 4. Auto Sync Real-Time Multi-Photo Updates
    
    func testAutoSyncRealTimeSliderUpdates() {
        let appState = AppState()
        
        let asset1 = makeTestAsset(filename: "a1.arw")
        let asset2 = makeTestAsset(filename: "a2.arw")
        let asset3 = makeTestAsset(filename: "a3.arw")
        
        appState.allAssets = [asset1, asset2, asset3]
        appState.selectedAssetIDs = [asset1.id, asset2.id]
        appState.primarySelectedAssetID = asset1.id
        
        // 1. Auto Sync is OFF by default -> updating a1 should NOT affect a2
        appState.isAutoSyncEnabled = false
        appState.updateDevelopSettings(for: asset1.id, isDragging: false) { xmp in
            xmp.exposure2012 = 0.50
        }
        
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == asset1.id })?.xmp.exposure2012, 0.50)
        XCTAssertNil(appState.allAssets.first(where: { $0.id == asset2.id })?.xmp.exposure2012)
        
        // 2. Enable Auto Sync -> slider change on a1 propagates instantly to a2
        appState.isAutoSyncEnabled = true
        appState.updateDevelopSettings(for: asset1.id, isDragging: false) { xmp in
            xmp.exposure2012 = 1.20
            xmp.contrast2012 = 20
        }
        
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == asset1.id })?.xmp.exposure2012, 1.20)
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == asset2.id })?.xmp.exposure2012, 1.20)
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == asset2.id })?.xmp.contrast2012, 20)
        
        // Unselected a3 must remain unaffected
        XCTAssertNil(appState.allAssets.first(where: { $0.id == asset3.id })?.xmp.exposure2012)
        
        // 3. Auto Tone with Auto Sync ON
        appState.autoTone(for: asset1.id)
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == asset1.id })?.xmp.highlights2012, -30)
        XCTAssertEqual(appState.allAssets.first(where: { $0.id == asset2.id })?.xmp.highlights2012, -30)
        
        // 4. Reset with Auto Sync ON
        appState.resetDevelopSettings(for: asset1.id)
        XCTAssertNil(appState.allAssets.first(where: { $0.id == asset1.id })?.xmp.exposure2012)
        XCTAssertNil(appState.allAssets.first(where: { $0.id == asset2.id })?.xmp.exposure2012)
    }
}
