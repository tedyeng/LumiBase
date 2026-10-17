import XCTest
import CoreImage
@testable import LumiBase

final class DevelopEnhancementsTests: XCTestCase {
    private var savedEngine: String?
    
    override func setUp() {
        super.setUp()
        savedEngine = UserDefaults.standard.string(forKey: "rawColorPipelineEngine")
        UserDefaults.standard.set(RAWColorPipelineEngine.adobePV2012.rawValue, forKey: "rawColorPipelineEngine")
    }
    
    override func tearDown() {
        if let savedEngine {
            UserDefaults.standard.set(savedEngine, forKey: "rawColorPipelineEngine")
        } else {
            UserDefaults.standard.removeObject(forKey: "rawColorPipelineEngine")
        }
        super.tearDown()
    }
    
    // MARK: - Tone Curve Data Tests
    
    func testToneCurveLinearIdentity() {
        let linear = ToneCurveData.linear
        XCTAssertTrue(linear.isLinear)
        XCTAssertEqual(linear.rgbPoints.count, 2)
        XCTAssertEqual(linear.rgbPoints.first?.x, 0.0)
        XCTAssertEqual(linear.rgbPoints.first?.y, 0.0)
        XCTAssertEqual(linear.rgbPoints.last?.x, 255.0)
        XCTAssertEqual(linear.rgbPoints.last?.y, 255.0)
        
        let lut = ToneCurveData.evaluateLUT(for: linear.rgbPoints)
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut[0], 0.0, accuracy: 0.01)
        XCTAssertEqual(lut[128], 0.5, accuracy: 0.02)
        XCTAssertEqual(lut[255], 1.0, accuracy: 0.01)
    }
    
    func testToneCurvePresets() {
        let medium = ToneCurveData.mediumContrast
        XCTAssertFalse(medium.isLinear)
        XCTAssertEqual(medium.rgbPoints.count, 6)
        
        let lutMed = ToneCurveData.evaluateLUT(for: medium.rgbPoints)
        XCTAssertEqual(lutMed.count, 256)
        // S-curve: shadow should be lower than linear, highlight should be higher
        XCTAssertLessThan(lutMed[64], Float(64.0 / 255.0))
        XCTAssertGreaterThan(lutMed[192], Float(192.0 / 255.0))
        
        let strong = ToneCurveData.strongContrast
        XCTAssertFalse(strong.isLinear)
        let lutStr = ToneCurveData.evaluateLUT(for: strong.rgbPoints)
        // Strong contrast deepens shadows even more than medium
        XCTAssertLessThan(lutStr[64], lutMed[64])
        XCTAssertGreaterThan(lutStr[192], lutMed[192])
    }
    
    func testToneCurvePointClamping() {
        let p = ToneCurvePoint(x: -50.0, y: 300.0)
        XCTAssertEqual(p.x, 0.0)
        XCTAssertEqual(p.y, 255.0)
    }
    
    // MARK: - HSL Adjustments Tests
    
    func testHSLAdjustmentsDefaultZero() {
        var hsl = HSLAdjustments.zero
        XCTAssertTrue(hsl.isZero)
        
        for band in HSLColorBand.allCases {
            XCTAssertEqual(hsl[band].hue, 0)
            XCTAssertEqual(hsl[band].saturation, 0)
            XCTAssertEqual(hsl[band].luminance, 0)
        }
        
        hsl.red.hue = 15
        XCTAssertFalse(hsl.isZero)
        XCTAssertEqual(hsl[.red].hue, 15)
    }
    
    func testHSLAdjustmentsSubscripts() {
        var hsl = HSLAdjustments()
        hsl[.blue].saturation = -50
        hsl[.green].luminance = 30
        hsl[.orange].hue = -10
        
        XCTAssertEqual(hsl.blue.saturation, -50)
        XCTAssertEqual(hsl.green.luminance, 30)
        XCTAssertEqual(hsl.orange.hue, -10)
    }
    
    // MARK: - XMP Roundtrip Tests for Curves & HSL
    
    func testToneCurveAndHSLRoundTrip() {
        var original = XMPMetadata()
        original.exposure2012 = 0.5
        
        // Custom Tone Curve
        var curve = ToneCurveData()
        curve.rgbPoints = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 64, y: 50),
            ToneCurvePoint(x: 128, y: 128),
            ToneCurvePoint(x: 192, y: 200),
            ToneCurvePoint(x: 255, y: 255)
        ]
        curve.redPoints = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 128, y: 140),
            ToneCurvePoint(x: 255, y: 255)
        ]
        original.toneCurve = curve
        
        // Custom HSL
        var hsl = HSLAdjustments()
        hsl.red.hue = 10
        hsl.red.saturation = -20
        hsl.red.luminance = 15
        hsl.blue.saturation = 35
        hsl.green.luminance = -40
        original.hsl = hsl
        
        XCTAssertTrue(original.hasDevelopEdits)
        
        // Generate XML and parse back
        let xml = XMPWriter.generateXMPXML(metadata: original, originalFilename: "DSC01234.ARW")
        let parsed = XMPParser.parse(data: xml.data(using: .utf8)!)
        
        // Verify Tone Curve RGB
        XCTAssertEqual(parsed.toneCurve.rgbPoints.count, 5)
        XCTAssertEqual(parsed.toneCurve.rgbPoints[1].x, 64, accuracy: 0.001)
        XCTAssertEqual(parsed.toneCurve.rgbPoints[1].y, 50, accuracy: 0.001)
        XCTAssertEqual(parsed.toneCurve.rgbPoints[3].x, 192, accuracy: 0.001)
        XCTAssertEqual(parsed.toneCurve.rgbPoints[3].y, 200, accuracy: 0.001)
        
        // Verify Tone Curve Red
        XCTAssertEqual(parsed.toneCurve.redPoints.count, 3)
        XCTAssertEqual(parsed.toneCurve.redPoints[1].x, 128, accuracy: 0.001)
        XCTAssertEqual(parsed.toneCurve.redPoints[1].y, 140, accuracy: 0.001)
        
        // Verify HSL
        XCTAssertEqual(parsed.hsl.red.hue, 10)
        XCTAssertEqual(parsed.hsl.red.saturation, -20)
        XCTAssertEqual(parsed.hsl.red.luminance, 15)
        XCTAssertEqual(parsed.hsl.blue.saturation, 35)
        XCTAssertEqual(parsed.hsl.green.luminance, -40)
        
        // Test Reset Develop Settings
        var reset = parsed
        reset.resetDevelopSettings()
        XCTAssertTrue(reset.toneCurve.isLinear)
        XCTAssertTrue(reset.hsl.isZero)
    }
    
    // MARK: - Develop Sync Options Tests
    
    func testDevelopSyncToneCurveAndColorMixer() {
        var src = XMPMetadata()
        src.exposure2012 = 1.0
        src.toneCurve = .strongContrast
        var hsl = HSLAdjustments()
        hsl.yellow.saturation = -30
        src.hsl = hsl
        
        var dst = XMPMetadata()
        
        // Sync without curve and color mixer
        var options = DevelopSyncOptions()
        options.exposure = true
        options.toneCurve = false
        options.colorMixer = false
        options.apply(from: src, to: &dst)
        
        XCTAssertEqual(dst.exposure2012, 1.0)
        XCTAssertTrue(dst.toneCurve.isLinear)
        XCTAssertTrue(dst.hsl.isZero)
        
        // Sync with curve and color mixer
        options.toneCurve = true
        options.colorMixer = true
        options.apply(from: src, to: &dst)
        
        XCTAssertFalse(dst.toneCurve.isLinear)
        XCTAssertEqual(dst.toneCurve.rgbPoints.count, 6)
        XCTAssertFalse(dst.hsl.isZero)
        XCTAssertEqual(dst.hsl.yellow.saturation, -30)
    }
    
    // MARK: - Auto Tone & Auto White Balance Tests
    
    func testAutoToneCalculationsOnSyntheticImage() {
        // Create an 8x8 synthetic mid-gray image with some dynamic range
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let grayColor = CIColor(red: 0.18, green: 0.18, blue: 0.18, colorSpace: linearSpace)!
        let grayImg = CIImage(color: grayColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        
        let autoTone = AutoToneService.shared.estimateAutoTone(from: grayImg)
        
        // Exposure should be reasonable (within [-3, 3])
        XCTAssertGreaterThanOrEqual(autoTone.exposure, -3.0)
        XCTAssertLessThanOrEqual(autoTone.exposure, 3.0)
        
        // Contrast within [-50, 50]
        XCTAssertGreaterThanOrEqual(autoTone.contrast, -50)
        XCTAssertLessThanOrEqual(autoTone.contrast, 50)
        
        // Highlights within [-100, 100]
        XCTAssertGreaterThanOrEqual(autoTone.highlights, -100)
        XCTAssertLessThanOrEqual(autoTone.highlights, 100)
        
        // Shadows within [-100, 100]
        XCTAssertGreaterThanOrEqual(autoTone.shadows, -100)
        XCTAssertLessThanOrEqual(autoTone.shadows, 100)
        
        // Whites within [-100, 100]
        XCTAssertGreaterThanOrEqual(autoTone.whites, -100)
        XCTAssertLessThanOrEqual(autoTone.whites, 100)
        
        // Blacks within [-100, 100]
        XCTAssertGreaterThanOrEqual(autoTone.blacks, -100)
        XCTAssertLessThanOrEqual(autoTone.blacks, 100)
    }
    
    func testAutoWhiteBalanceCalculationsOnSyntheticImage() {
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let neutralColor = CIColor(red: 0.20, green: 0.20, blue: 0.20, colorSpace: linearSpace)!
        let neutralImg = CIImage(color: neutralColor).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        
        let autoWB = AutoToneService.shared.estimateAutoWB(from: neutralImg)
        
        // Neutral gray image with Adobe warm offset (+23 mired) should yield ~5500K - 7000K
        XCTAssertGreaterThan(autoWB.temperature, 4500)
        XCTAssertLessThan(autoWB.temperature, 7500)
        
        // Tint should be around Adobe offset (-3)
        XCTAssertGreaterThan(autoWB.tint, -30)
        XCTAssertLessThan(autoWB.tint, 30)
    }
    
    func testThumbnailLoadingWithDevelopEdits() async throws {
        // Create a temporary synthetic image to test thumbnail loading with develop edits
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let imgURL = tempDir.appendingPathComponent("test_thumb.jpg")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 400, bitsPerPixel: 32)!
        let data = rep.representation(using: .jpeg, properties: [:])!
        try data.write(to: imgURL)
        
        var xmp = XMPMetadata()
        xmp.exposure2012 = 1.0
        xmp.contrast2012 = 25
        
        let asset = PhotoAsset(fileURL: imgURL, xmp: xmp)
        XCTAssertTrue(asset.xmp.hasDevelopEdits)
        
        let thumb = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 100)
        XCTAssertNotNil(thumb)
    }
    
    func testHSLAdjustmentsCacheIdentity() {
        var xmp = XMPMetadata()
        let id0 = xmp.thumbnailDevelopCacheIdentity
        
        // Changing Blue Luminance to 100 must alter thumbnailDevelopCacheIdentity
        xmp.hsl.blue.luminance = 100
        let id1 = xmp.thumbnailDevelopCacheIdentity
        XCTAssertNotEqual(id0, id1)
        XCTAssertTrue(id1.contains("hsl="))
        XCTAssertTrue(id1.contains("100"))
        
        // Changing ToneCurve must alter thumbnailDevelopCacheIdentity
        var xmp2 = XMPMetadata()
        let idCurve0 = xmp2.thumbnailDevelopCacheIdentity
        xmp2.toneCurve = .strongContrast
        let idCurve1 = xmp2.thumbnailDevelopCacheIdentity
        XCTAssertNotEqual(idCurve0, idCurve1)
    }
    
    func testColorMixerBlueLuminanceAdjustment() {
        // Create an image with sky blue color (R=0.25, G=0.60, B=0.90)
        let skyBlue = CIColor(red: 0.25, green: 0.60, blue: 0.90, alpha: 1.0)
        let img = CIImage(color: skyBlue).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let ctx = CIContext()
        
        func renderPixel(_ image: CIImage) -> (r: UInt8, g: UInt8, b: UInt8) {
            var pixel = [UInt8](repeating: 0, count: 4)
            ctx.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return (pixel[0], pixel[1], pixel[2])
        }
        
        let pBase = renderPixel(img)
        
        // Apply Blue Luminance +100
        var hslPlus = HSLAdjustments()
        hslPlus.blue.luminance = 100
        let imgPlus = ColorMixerKernel.apply(image: img, hsl: hslPlus)
        let pPlus = renderPixel(imgPlus)
        
        // Verify Luminance +100 increases lightness (overall brightness rises)
        let lumBase = 0.2126 * Double(pBase.r) + 0.7152 * Double(pBase.g) + 0.0722 * Double(pBase.b)
        let lumPlus = 0.2126 * Double(pPlus.r) + 0.7152 * Double(pPlus.g) + 0.0722 * Double(pPlus.b)
        XCTAssertGreaterThan(lumPlus, lumBase + 10.0, "Blue Luminance +100 must visibly brighten the sky color")
        
        // Apply Blue Luminance -100
        var hslMinus = HSLAdjustments()
        hslMinus.blue.luminance = -100
        let imgMinus = ColorMixerKernel.apply(image: img, hsl: hslMinus)
        let pMinus = renderPixel(imgMinus)
        let lumMinus = 0.2126 * Double(pMinus.r) + 0.7152 * Double(pMinus.g) + 0.0722 * Double(pMinus.b)
        XCTAssertLessThan(lumMinus, lumBase - 10.0, "Blue Luminance -100 must visibly darken the sky color")
        
        // Non-blue colors (e.g. Red) should not be affected by Blue slider
        let redColor = CIColor(red: 0.90, green: 0.20, blue: 0.20, alpha: 1.0)
        let redImg = CIImage(color: redColor).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let redBase = renderPixel(redImg)
        let redWithBlueAdj = ColorMixerKernel.apply(image: redImg, hsl: hslPlus)
        let redAfter = renderPixel(redWithBlueAdj)
        XCTAssertEqual(redBase.r, redAfter.r)
        XCTAssertEqual(redBase.g, redAfter.g)
        XCTAssertEqual(redBase.b, redAfter.b)
    }
    
    func testSkyAndWaterColorMixerShifts() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        let xmpURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.xmp")
        guard FileManager.default.fileExists(atPath: arwURL.path),
              let xmpData = try? Data(contentsOf: xmpURL) else { return }
        
        let xmp = XMPParser.parse(data: xmpData)
        guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: arwURL, xmp: xmp) else { return }
        
        let ctx = CIContext()
        var xmpZero = xmp
        xmpZero.hsl = .zero
        let processed0 = AdobeColorPipeline.shared.process(image: holder.interactive, cameraModel: "ILCE-7CM2", xmp: xmpZero, baseHolder: holder)
        
        var xmpBlueHue100 = xmpZero
        xmpBlueHue100.hsl.blue.hue = 100
        let processedBlueHue100 = AdobeColorPipeline.shared.process(image: holder.interactive, cameraModel: "ILCE-7CM2", xmp: xmpBlueHue100, baseHolder: holder)
        
        func sampleHue(img: CIImage, x: CGFloat, y: CGFloat) -> Double {
            var pixel = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let r = Double(pixel[0]) / 255.0
            let g = Double(pixel[1]) / 255.0
            let b = Double(pixel[2]) / 255.0
            let maxV = max(r, max(g, b))
            let minV = min(r, min(g, b))
            let delta = maxV - minV
            var h = 0.0
            if delta > 1e-4 {
                if r == maxV { h = (g - b) / delta + (g < b ? 6 : 0) }
                else if g == maxV { h = (b - r) / delta + 2 }
                else { h = (r - g) / delta + 4 }
                h *= 60.0
            }
            return h
        }
        
        let w = holder.interactiveExtent.width
        let h = holder.interactiveExtent.height
        let h0 = sampleHue(img: processed0, x: w * 0.8, y: h * 0.8)
        let hBlue = sampleHue(img: processedBlueHue100, x: w * 0.8, y: h * 0.8)
        
        // Sky Top Right must shift by at least 25 degrees when Blue Hue is set to +100
        XCTAssertGreaterThan(hBlue - h0, 25.0, "Sky hue must rotate significantly towards purple when Blue Hue is +100")
    }
    
    func testThumbnailLoaderResetBehavior() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        let companionURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.jpg")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }
        
        var xmpBlue100 = XMPMetadata()
        xmpBlue100.highlights2012 = -100
        xmpBlue100.hsl.blue.hue = 100
        let assetBlue100 = PhotoAsset(fileURL: arwURL, companionURLs: [companionURL], xmp: xmpBlue100)
        
        var xmpReset = XMPMetadata()
        xmpReset.highlights2012 = -100
        xmpReset.hsl = .zero
        let assetReset = PhotoAsset(fileURL: arwURL, companionURLs: [companionURL], xmp: xmpReset)
        
        let thumbBlue100 = await ThumbnailLoader.shared.loadThumbnail(for: assetBlue100, maxPixelSize: 440)
        let thumbReset = await ThumbnailLoader.shared.loadThumbnail(for: assetReset, maxPixelSize: 440)
        
        XCTAssertNotNil(thumbBlue100)
        XCTAssertNotNil(thumbReset)
        
        let repBlue = NSBitmapImageRep(data: thumbBlue100!.tiffRepresentation!)!
        let repReset = NSBitmapImageRep(data: thumbReset!.tiffRepresentation!)!
        
        let x = Int(CGFloat(repBlue.pixelsWide) * 0.8)
        let y = Int(CGFloat(repBlue.pixelsHigh) * 0.2)
        let cBlue = repBlue.colorAt(x: x, y: y)!
        let cReset = repReset.colorAt(x: x, y: y)!
        
        print("Blue100 sky color at (\(x), \(y)): R=\(cBlue.redComponent) G=\(cBlue.greenComponent) B=\(cBlue.blueComponent)")
        print("Reset sky color at (\(x), \(y)): R=\(cReset.redComponent) G=\(cReset.greenComponent) B=\(cReset.blueComponent)")
    }
    
    func testCachedMemoryThumbnailAfterLoading() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        let companionURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.jpg")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }
        
        var xmp0 = XMPMetadata()
        xmp0.highlights2012 = -100
        xmp0.hsl = .zero
        let asset0 = PhotoAsset(fileURL: arwURL, companionURLs: [companionURL], xmp: xmp0)
        
        let mem0 = ThumbnailLoader.cachedMemoryThumbnail(for: asset0, maxPixelSize: 440)
        print("mem0 before loadThumbnail:", mem0 != nil)
        
        _ = await ThumbnailLoader.shared.loadThumbnail(for: asset0, maxPixelSize: 440)
        
        let mem1 = ThumbnailLoader.cachedMemoryThumbnail(for: asset0, maxPixelSize: 440)
        print("mem1 after loadThumbnail:", mem1 != nil)
        
        let diskKey = ThumbnailLoader.cacheKey(for: asset0, maxPixelSize: 440)
        let cachedFromDisk = ThumbnailCacheManager.shared.image(forKey: diskKey)
        print("diskKey: \(diskKey)")
        print("cachedFromDisk != nil: \(cachedFromDisk != nil)")
        if let img = cachedFromDisk, let rep = NSBitmapImageRep(data: img.tiffRepresentation!) {
            let x = Int(CGFloat(rep.pixelsWide) * 0.8)
            let y = Int(CGFloat(rep.pixelsHigh) * 0.2)
            let c = rep.colorAt(x: x, y: y)!
            print("cachedFromDisk sky color: R=\(c.redComponent) G=\(c.greenComponent) B=\(c.blueComponent)")
        }
    }
    
    @MainActor
    func testAppStateDevelopSettingsResetFlow() async throws {
        let appState = AppState()
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        let companionURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.jpg")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }
        
        var xmpInit = XMPMetadata()
        xmpInit.highlights2012 = -100
        let asset = PhotoAsset(fileURL: arwURL, companionURLs: [companionURL], xmp: xmpInit)
        
        appState.allAssets = [asset]
        appState.primarySelectedAssetID = asset.id
        
        // 1. Initial key
        let initialKey = ThumbnailLoader.cacheKey(for: appState.displayedAssets[0], maxPixelSize: 440)
        print("Initial key: \(initialKey)")
        
        // 2. User adjusts Blue Hue to +100
        appState.updateDevelopSettings(for: asset.id, isDragging: true) { xmp in
            xmp.hsl.blue.hue = 100
        }
        print("While dragging key: \(ThumbnailLoader.cacheKey(for: appState.displayedAssets[0], maxPixelSize: 440))")
        
        // 3. User releases mouse
        appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
        let editedKey = ThumbnailLoader.cacheKey(for: appState.displayedAssets[0], maxPixelSize: 440)
        print("Edited key: \(editedKey)")
        XCTAssertNotEqual(initialKey, editedKey)
        
        // 4. User clicks Reset button in ColorMixerPanelView
        appState.updateDevelopSettings(for: asset.id, isDragging: false) { xmp in
            xmp.hsl = .zero
        }
        let resetKey = ThumbnailLoader.cacheKey(for: appState.displayedAssets[0], maxPixelSize: 440)
        print("Reset key: \(resetKey)")
        XCTAssertEqual(initialKey, resetKey)
        XCTAssertTrue(appState.displayedAssets[0].xmp.hsl.isZero)
    }
    
    func testPhotoAssetHashIncludesDevelopIdentity() {
        let dummyURL = URL(fileURLWithPath: "/tmp/test.arw")
        let xmpBase = XMPMetadata()
        let assetBase = PhotoAsset(fileURL: dummyURL, xmp: xmpBase)
        
        var xmpEdited = xmpBase
        xmpEdited.hsl.blue.hue = 100
        let assetEdited = PhotoAsset(fileURL: dummyURL, xmp: xmpEdited)
        
        var xmpReset = xmpEdited
        xmpReset.hsl = .zero
        let assetReset = PhotoAsset(fileURL: dummyURL, xmp: xmpReset)
        
        XCTAssertNotEqual(assetBase.hashValue, assetEdited.hashValue, "PhotoAsset hash must change when develop edits are applied")
        XCTAssertEqual(assetBase.hashValue, assetReset.hashValue, "PhotoAsset hash must return to base hash when reset")
        XCTAssertNotEqual(assetEdited.hashValue, assetReset.hashValue, "PhotoAsset hash must change when reset from edited state")
    }
    
    func testAdaptiveContrastPivotCalculation() {
        let pivotMid = AutoToneService.calculateContrastPivot(meanLuma: 0.50, middleLuma: 0.50)
        XCTAssertGreaterThanOrEqual(pivotMid, 0.35)
        XCTAssertLessThanOrEqual(pivotMid, 0.65)
        
        let pivotLow = AutoToneService.calculateContrastPivot(meanLuma: 0.0, middleLuma: 1.0)
        XCTAssertEqual(pivotLow, 0.35, accuracy: 0.001)
        
        let pivotHigh = AutoToneService.calculateContrastPivot(meanLuma: 1.0, middleLuma: 0.0)
        XCTAssertEqual(pivotHigh, 0.65, accuracy: 0.001)
    }
    
    func testBlackAndWhiteMixViaHSLLuminance() {
        let skyBlue = CIColor(red: 0.20, green: 0.55, blue: 0.90, alpha: 1.0)
        let img = CIImage(color: skyBlue).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let ctx = CIContext()
        
        func renderGray(_ image: CIImage) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            ctx.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return pixel[0]
        }
        
        var xmpBWZero = XMPMetadata()
        xmpBWZero.convertToGrayscale = true
        let bwZeroImg = AdobeColorPipeline.shared.process(image: img, cameraModel: nil, xmp: xmpBWZero)
        let lumaZero = renderGray(bwZeroImg)
        
        var xmpBWDarkSky = xmpBWZero
        xmpBWDarkSky.hsl.blue.luminance = -80
        let bwDarkImg = AdobeColorPipeline.shared.process(image: img, cameraModel: nil, xmp: xmpBWDarkSky)
        let lumaDark = renderGray(bwDarkImg)
        
        XCTAssertLessThan(lumaDark, lumaZero - 20, "Adjusting Blue Luminance in B&W mode must darken blue sky tones (8-band B&W Mix)")
    }
    
    func testStandardAdobeSeqToneCurveParsing() {
        let adobeXMP = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
           <crs:ToneCurvePV2012>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>32, 22</rdf:li>
             <rdf:li>64, 56</rdf:li>
             <rdf:li>128, 128</rdf:li>
             <rdf:li>192, 196</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let parsed = XMPParser.parse(data: adobeXMP.data(using: .utf8)!)
        XCTAssertEqual(parsed.toneCurve.rgbPoints.count, 6)
        XCTAssertEqual(parsed.toneCurve.rgbPoints[1].x, 32, accuracy: 0.001)
        XCTAssertEqual(parsed.toneCurve.rgbPoints[1].y, 22, accuracy: 0.001)
    }
    
    func testColorMixerSelectiveHSLNoShadowArtifacts() {
        var hsl = HSLAdjustments()
        hsl.red.saturation = 30
        hsl.red.luminance = 30
        hsl.orange.saturation = -30
        hsl.orange.luminance = 30
        hsl.yellow.saturation = -40
        hsl.yellow.luminance = 30
        
        let ctx = CIContext()
        // Test shadow pixel (R=0.25, G=0.22, B=0.18) with slight warm cast
        let shadowColor = CIColor(red: 0.25, green: 0.22, blue: 0.18, alpha: 1.0)
        let shadowImg = CIImage(color: shadowColor).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let outputShadow = ColorMixerKernel.apply(image: shadowImg, hsl: hsl)
        var shadowPixel = [UInt8](repeating: 0, count: 4)
        ctx.render(outputShadow, toBitmap: &shadowPixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        
        // Shadow should remain deep shadow (RGB < 80), not blow up to 150+
        XCTAssertLessThan(shadowPixel[0], 80, "Shadow red should remain dark, not blown out by HSL luminance")
        XCTAssertLessThan(shadowPixel[1], 75, "Shadow green should remain dark")
        XCTAssertLessThan(shadowPixel[2], 70, "Shadow blue should remain dark")
        
        // Test saturated skin tone pixel (R=0.80, G=0.55, B=0.40)
        let skinColor = CIColor(red: 0.80, green: 0.55, blue: 0.40, alpha: 1.0)
        let skinImg = CIImage(color: skinColor).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let outputSkin = ColorMixerKernel.apply(image: skinImg, hsl: hsl)
        var skinPixel = [UInt8](repeating: 0, count: 4)
        ctx.render(outputSkin, toBitmap: &skinPixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        
        // Skin tone with Orange/Red luminance +30 should be brightened smoothly
        XCTAssertGreaterThan(skinPixel[0], 200)
    }
}
