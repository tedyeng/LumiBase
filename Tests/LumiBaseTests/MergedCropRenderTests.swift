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

    func testCropOverlayRotateZoneHitTesting() {
        let cropRect = CGRect(x: 100, y: 100, width: 400, height: 300)

        // Outside corners and edges should activate rotation
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 70, y: 70), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 530, y: 70), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 70, y: 430), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 530, y: 430), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 50, y: 250), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 550, y: 250), cropRect: cropRect))

        // Border edges between resize handles should also activate rotation
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 200, y: 102), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 400, y: 398), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 102, y: 180), cropRect: cropRect))
        XCTAssertTrue(CropOverlayView.isPointInRotateZone(CGPoint(x: 498, y: 320), cropRect: cropRect))

        // All 8 resize handles must remain reserved for resizing
        for handle in CropHandle.allCases {
            let pos = CropOverlayView.handlePosition(for: handle, cropRect: cropRect)
            XCTAssertFalse(CropOverlayView.isPointInRotateZone(pos, cropRect: cropRect), "Handle \(handle) should not be in rotate zone")
        }

        // Interior of the crop box must remain reserved for panning
        XCTAssertFalse(CropOverlayView.isPointInRotateZone(CGPoint(x: 300, y: 250), cropRect: cropRect))
        XCTAssertFalse(CropOverlayView.isPointInRotateZone(CGPoint(x: 150, y: 150), cropRect: cropRect))
    }

    func testCropOverlayRotationAngleMathAndSeamWrap() {
        // Clockwise drag on screen (+10 deg in Y-down SwiftUI) -> -10.0 deg cropAngle
        let cwAngle = CropOverlayView.updatedCropAngle(initialAngle: 0.0, accumulatedDeltaRadians: 10.0 * .pi / 180.0)
        XCTAssertEqual(cwAngle, -10.0, accuracy: 0.001)

        // Counter-clockwise drag (-12.34 deg) -> +12.3 deg cropAngle
        let ccwAngle = CropOverlayView.updatedCropAngle(initialAngle: 0.0, accumulatedDeltaRadians: -12.34 * .pi / 180.0)
        XCTAssertEqual(ccwAngle, 12.3, accuracy: 0.001)

        // Clamping to -45...45
        XCTAssertEqual(CropOverlayView.updatedCropAngle(initialAngle: 40.0, accumulatedDeltaRadians: -20.0 * .pi / 180.0), 45.0, accuracy: 0.001)
        XCTAssertEqual(CropOverlayView.updatedCropAngle(initialAngle: -40.0, accumulatedDeltaRadians: 20.0 * .pi / 180.0), -45.0, accuracy: 0.001)

        // Crossing the -pi/+pi seam on the left side produces a small continuous delta
        let step = CropOverlayView.wrappedAngleDeltaRadians(from: 3.10, to: -3.10)
        XCTAssertGreaterThan(step, 0.0)
        XCTAssertLessThan(step, 0.2)
        XCTAssertEqual(step, (2.0 * .pi) - 6.20, accuracy: 1e-6)
    }

    func testCropOverlayRotateCursorSectorsMatchAllEdgesAndCorners() {
        let center = CGPoint(x: 300, y: 250)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 500, y: 250), center: center), 0) // right (0 deg)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 450, y: 100), center: center), 1) // top-right (45 deg)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 300, y: 50), center: center), 2)  // top (90 deg)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 150, y: 100), center: center), 3) // top-left (135 deg)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 100, y: 250), center: center), 4) // left (180 deg, opposite right)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 150, y: 400), center: center), 5) // bottom-left (225 deg)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 300, y: 450), center: center), 6) // bottom (270 deg)
        XCTAssertEqual(CropOverlayView.rotateCursorSector(for: CGPoint(x: 450, y: 400), center: center), 7) // bottom-right (315 deg)
    }

    func testPhotoOrientationTransformGroupAlgebra() {
        for state in PhotoOrientationTransform.allCases {
            // 4x 90° CW or CCW returns to original state
            XCTAssertEqual(
                state.rotatedClockwise90().rotatedClockwise90().rotatedClockwise90().rotatedClockwise90(),
                state
            )
            XCTAssertEqual(
                state.rotatedCounterClockwise90().rotatedCounterClockwise90().rotatedCounterClockwise90().rotatedCounterClockwise90(),
                state
            )
            // CW and CCW are exact inverses
            XCTAssertEqual(state.rotatedClockwise90().rotatedCounterClockwise90(), state)
            XCTAssertEqual(state.rotatedCounterClockwise90().rotatedClockwise90(), state)
            // Horizontal and vertical flips are involutions
            XCTAssertEqual(state.flippedHorizontal().flippedHorizontal(), state)
            XCTAssertEqual(state.flippedVertical().flippedVertical(), state)
            // Flip H then Flip V equals 180° rotation
            XCTAssertEqual(
                state.flippedHorizontal().flippedVertical(),
                state.rotatedClockwise90().rotatedClockwise90()
            )
        }
    }

    func testApplyOrientationTransformPixelDirections() {
        // Non-square 120x80 image (CoreImage Y-up: y=65 is near top, x=15 is near left)
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        // Dot near top-center: x=57..63, y=67..73 (in Y-up, top is y=80)
        let topDot = CIImage(color: .white).cropped(to: CGRect(x: 57, y: 67, width: 6, height: 6)).composited(over: black)
        // Dot near left-center: x=7..13, y=37..43
        let leftDot = CIImage(color: .white).cropped(to: CGRect(x: 7, y: 37, width: 6, height: 6)).composited(over: black)

        func brightestCGPoint(in image: CIImage) -> (x: Int, y: Int, w: Int, h: Int) {
            let ctx = CIContext(options: nil)
            let cg = ctx.createCGImage(image, from: image.extent)!
            let w = cg.width, h = cg.height, bpr = w * 4
            var pixels = [UInt8](repeating: 0, count: bpr * h)
            let bm = CGContext(
                data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            bm.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var bestSum = -1, bestX = -1, bestY = -1
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * bpr + x * 4
                    let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                    if sum > bestSum { bestSum = sum; bestX = x; bestY = y }
                }
            }
            return (bestX, bestY, w, h)
        }

        // 1. Rotate 90° CW (.right): 120x80 -> 80x120, top-center dot moves to right-center (x > w/2)
        let cw = AdobeColorPipeline.shared.applyOrientationTransform(image: topDot, orientation: .right)
        let cwPos = brightestCGPoint(in: cw)
        XCTAssertEqual(cwPos.w, 80)
        XCTAssertEqual(cwPos.h, 120)
        XCTAssertGreaterThan(cwPos.x, cwPos.w * 3 / 4, "90° CW should move top dot to right side")

        // 2. Rotate 90° CCW (.left): 120x80 -> 80x120, top-center dot moves to left-center (x < w/4)
        let ccw = AdobeColorPipeline.shared.applyOrientationTransform(image: topDot, orientation: .left)
        let ccwPos = brightestCGPoint(in: ccw)
        XCTAssertEqual(ccwPos.w, 80)
        XCTAssertEqual(ccwPos.h, 120)
        XCTAssertLessThan(ccwPos.x, ccwPos.w / 4, "90° CCW should move top dot to left side")

        // 3. Flip Horizontal (.upMirrored): left-center dot moves to right-center (x > w*3/4)
        let flipH = AdobeColorPipeline.shared.applyOrientationTransform(image: leftDot, orientation: .upMirrored)
        let flipHPos = brightestCGPoint(in: flipH)
        XCTAssertEqual(flipHPos.w, 120)
        XCTAssertEqual(flipHPos.h, 80)
        XCTAssertGreaterThan(flipHPos.x, flipHPos.w * 3 / 4, "Flip H should move left dot to right side")

        // 4. Flip Vertical (.downMirrored): top-center dot moves to bottom-center (CGContext y > h*3/4)
        let flipV = AdobeColorPipeline.shared.applyOrientationTransform(image: topDot, orientation: .downMirrored)
        let flipVPos = brightestCGPoint(in: flipV)
        XCTAssertEqual(flipVPos.w, 120)
        XCTAssertEqual(flipVPos.h, 80)
        XCTAssertGreaterThan(flipVPos.y, flipVPos.h * 3 / 4, "Flip V should move top dot to bottom side")

        // 5. Full main AdobeColorPipeline.process(...) AND InspectionFrameLayout.processedFullExtent must apply orientation
        var rotXMP = XMPMetadata.empty
        rotXMP.orientationTransform = .right
        let processedMain = AdobeColorPipeline.shared.process(image: topDot, cameraModel: nil, xmp: rotXMP, isRaw: false)
        let processedMainPos = brightestCGPoint(in: processedMain)
        XCTAssertEqual(processedMainPos.w, 80, "Main process() pipeline must swap dimensions on 90° rotation")
        XCTAssertEqual(processedMainPos.h, 120)
        XCTAssertGreaterThan(processedMainPos.x, processedMainPos.w * 3 / 4)

        let fullExtent = InspectionFrameLayout.processedFullExtent(source: CGRect(x: 0, y: 0, width: 120, height: 80), xmp: rotXMP)
        XCTAssertEqual(fullExtent.size, CGSize(width: 80, height: 120))

        // 6. RAWImageLoader.renderProcessed must swap output raster dimensions on 90° rotation even when hasCrop == false
        let holder = BaseImageHolder(
            full: topDot, display: topDot, interactive: topDot,
            fullExtent: topDot.extent, displayExtent: topDot.extent, interactiveExtent: topDot.extent,
            baseTemperature: nil, baseTint: nil, baseExposure: nil, isRaw: false
        )
        let rendered = RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: rotXMP, interactive: false)
        XCTAssertNotNil(rendered)
        let renderedCG = rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertEqual(renderedCG?.width, 80, "90° rotated render must have swapped width=80, not unrotated 120")
        XCTAssertEqual(renderedCG?.height, 120, "90° rotated render must have swapped height=120, not unrotated 80")
    }

    func testOrientationTransformXMPRoundTrip() {
        var xmp = XMPMetadata.empty
        xmp.orientationTransform = .right
        XCTAssertTrue(xmp.hasDevelopEdits)
        XCTAssertTrue(xmp.hasOrientationTransform)

        let xml = XMPWriter.generateXMPXML(metadata: xmp, originalFilename: "DSC0001.ARW")
        XCTAssertTrue(xml.contains("lumibase:OrientationTransform=\"6\""))

        let parsed = XMPParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(parsed.orientationTransform, PhotoOrientationTransform.right)
        XCTAssertTrue(parsed.hasDevelopEdits)
    }

    @MainActor
    func testRotateAndFlipSelectedPhotosInLibraryMode() {
        let appState = AppState()
        appState.workspaceMode = .library
        let meta = CameraMetadata(pixelWidth: 6000, pixelHeight: 4000)
        let a1 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/rot1.ARW"), cameraMetadata: meta)
        let a2 = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/rot2.ARW"), cameraMetadata: meta)
        appState.allAssets = [a1, a2]
        appState.selectedAssetIDs = [a1.id, a2.id]
        appState.primarySelectedAssetID = a1.id

        let rev0 = appState.displaySourceRevision
        appState.rotateSelectedPhotosRight()
        XCTAssertEqual(appState.workspaceMode, .library, "Rotating in Library mode should not switch workspace")
        XCTAssertEqual(appState.allAssets[0].xmp.orientationTransform, .right)
        XCTAssertEqual(appState.allAssets[1].xmp.orientationTransform, .right)
        XCTAssertGreaterThan(appState.displaySourceRevision, rev0)

        let dims = appState.assetDimensions(for: appState.allAssets[0])
        XCTAssertEqual(dims.width, 4000)
        XCTAssertEqual(dims.height, 6000)

        appState.flipSelectedPhotosHorizontal()
        XCTAssertEqual(appState.allAssets[0].xmp.orientationTransform, .leftMirrored)

        appState.rotateSelectedPhotosLeft()
        XCTAssertEqual(appState.allAssets[0].xmp.orientationTransform, .downMirrored)

        appState.flipSelectedPhotosVertical()
        XCTAssertEqual(appState.allAssets[0].xmp.orientationTransform, .up)
    }
}
