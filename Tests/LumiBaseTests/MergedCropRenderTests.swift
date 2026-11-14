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

    func testDevelopProcessedFullExtentMatchesCroppedRaster() throws {
        let fullRect = CGRect(x: 0, y: 0, width: 6000, height: 4000)
        var settings = XMPMetadata()
        settings.hasCrop = true
        settings.cropLeft = 0.1
        settings.cropRight = 0.9
        settings.cropTop = 0.2
        settings.cropBottom = 0.8
        
        let extent = InspectionFrameLayout.processedFullExtent(source: fullRect, xmp: settings)
        XCTAssertEqual(extent.width, 4800) // (0.9 - 0.1) * 6000
        XCTAssertEqual(extent.height, 2400) // (0.8 - 0.2) * 4000
        XCTAssertEqual(extent.width / extent.height, 2.0)
    }

    @MainActor
    func testSetCropPresetUsesAssetDimensions() {
        let appState = AppState()
        var metadata = CameraMetadata()
        metadata.pixelWidth = 4000
        metadata.pixelHeight = 6000 // Portrait photo
        
        let asset = PhotoAsset(
            fileURL: URL(fileURLWithPath: "/tmp/portrait.ARW"),
            cameraMetadata: metadata
        )
        
        appState.allAssets = [asset]
        appState.primarySelectedAssetID = asset.id
        
        appState.setCropPreset(.square1x1)
        
        guard let xmp = appState.primarySelectedAsset?.xmp else {
            XCTFail("Asset XMP missing")
            return
        }
        
        let g = xmp.cropGeometry
        let pixelW = g.widthFraction * 4000.0
        let pixelH = g.heightFraction * 6000.0
        
        // Pixel aspect ratio must be 1.0 (square)
        XCTAssertEqual(pixelW / pixelH, 1.0, accuracy: 0.01)
    }

    @MainActor
    func testFlipCropOrientationInvertsPixelAspect() {
        let appState = AppState()
        var metadata = CameraMetadata()
        metadata.pixelWidth = 6000
        metadata.pixelHeight = 4000 // 3:2 landscape
        
        var xmp = XMPMetadata()
        xmp.cropGeometry = CropGeometry(top: 0.1, left: 0.1, bottom: 0.7, right: 0.9)
        // curPixelW = 0.8 * 6000 = 4800
        // curPixelH = 0.6 * 4000 = 2400
        // aspect = 2.0 (landscape)
        
        let asset = PhotoAsset(
            fileURL: URL(fileURLWithPath: "/tmp/flip.ARW"),
            xmp: xmp,
            cameraMetadata: metadata
        )
        
        appState.allAssets = [asset]
        appState.primarySelectedAssetID = asset.id
        
        appState.flipCropOrientation()
        
        guard let flippedXMP = appState.primarySelectedAsset?.xmp else {
            XCTFail("Asset XMP missing")
            return
        }
        
        let g = flippedXMP.cropGeometry
        let newPixelW = g.widthFraction * 6000.0
        let newPixelH = g.heightFraction * 4000.0
        
        // Inverted aspect: was 2.0 (2:1), should now be 0.5 (1:2 portrait)
        XCTAssertEqual(newPixelW / newPixelH, 0.5, accuracy: 0.02)
    }

    @MainActor
    func testCropToolGeometryCommitDoesNotIncrementDisplaySourceRevision() {
        let appState = AppState()
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/crop_smooth.ARW"))
        appState.allAssets = [asset]
        appState.primarySelectedAssetID = asset.id
        appState.workspaceMode = .develop
        appState.activeDevelopTool = .crop

        let initialRevision = appState.displaySourceRevision
        let targetGeometry = CropGeometry(top: 0.15, left: 0.1, bottom: 0.85, right: 0.9)
        appState.updateCropGeometry(targetGeometry, isDragging: false)

        XCTAssertEqual(appState.displaySourceRevision, initialRevision)
        XCTAssertEqual(appState.primarySelectedAsset?.xmp.cropGeometry, targetGeometry)
    }

    @MainActor
    func testCompleteCropEditingKeepsCropPanelActiveWhileClosingOverlay() {
        let appState = AppState()
        appState.toggleCropMode()
        XCTAssertEqual(appState.activeDevelopTool, .crop)
        XCTAssertTrue(appState.isCropOverlayActive)
        XCTAssertTrue(appState.isEditingCropOverlay)

        // Completing crop (Done / Return) closes the interactive overlay to display the cropped result,
        // while keeping the right inspector on the Crop & Straighten panel.
        appState.completeCropEditing()
        XCTAssertEqual(appState.activeDevelopTool, .crop)
        XCTAssertFalse(appState.isCropOverlayActive)
        XCTAssertFalse(appState.isEditingCropOverlay)

        // Pressing R / toggling crop mode again re-opens the interactive crop overlay.
        appState.toggleCropMode()
        XCTAssertEqual(appState.activeDevelopTool, .crop)
        XCTAssertTrue(appState.isCropOverlayActive)
        XCTAssertTrue(appState.isEditingCropOverlay)
    }

    func testPositiveCropAngleRotatesCounterClockwiseMatchingSwiftUIOverlay() {
        // Place a bright spot at top-center (x=50, y=80 in CoreImage Y-up 100x100)
        // A positive angle (+15 deg) should rotate CCW on screen (top-center moves left: x < 50).
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let dot = CIImage(color: .white).cropped(to: CGRect(x: 47, y: 75, width: 6, height: 6))
        let source = dot.composited(over: black)

        var xmp = XMPMetadata.empty
        xmp.cropAngle = 15.0
        let rotated = AdobeColorPipeline.shared.applyCrop(image: source, xmp: xmp)

        let ctx = CIContext(options: nil)
        let outExtent = rotated.extent
        guard let cg = ctx.createCGImage(rotated, from: outExtent) else {
            return XCTFail("Failed to render rotated image")
        }
        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapCtx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return XCTFail("Failed to create bitmap context")
        }
        bitmapCtx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Find brightest pixel in top half (CGContext top-left origin: y < height / 2)
        var maxSum = -1
        var maxX = -1
        for y in 0..<(height / 2) {
            for x in 0..<width {
                let idx = y * bytesPerRow + x * 4
                let lum = Int(pixels[idx]) + Int(pixels[idx + 1]) + Int(pixels[idx + 2])
                if lum > maxSum {
                    maxSum = lum
                    maxX = x
                }
            }
        }
        XCTAssertGreaterThan(maxSum, 300)
        XCTAssertLessThan(maxX, width / 2, "Positive cropAngle should rotate CCW so top-center moves left")
    }
}
