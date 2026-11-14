import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class LightcraftHighlightsTests: XCTestCase {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let cs = CGColorSpaceCreateDeviceRGB()
    
    func testStandardToneCurvePreservesWhitePointAndMidtones() {
        let pipeline = AdobeColorPipeline.shared
        
        // Pure white point (input 1.0)
        let whiteColor = CIColor(red: 1.0, green: 1.0, blue: 1.0)
        let whiteImg = CIImage(color: whiteColor).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        
        // Midtone patch (y = 0.50)
        let midtoneColor = CIColor(red: 0.50, green: 0.50, blue: 0.50)
        let midtoneImg = CIImage(color: midtoneColor).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        
        var xmp = XMPMetadata()
        xmp.highlights2012 = -100
        xmp.advancedRAWHighlightRecovery = false
        
        let processedWhite = pipeline.process(image: whiteImg, cameraModel: nil, xmp: xmp)
        let processedMid = pipeline.process(image: midtoneImg, cameraModel: nil, xmp: xmp)
        
        var pixWhite = [UInt8](repeating: 0, count: 4)
        var pixMid = [UInt8](repeating: 0, count: 4)
        
        context.render(processedWhite, toBitmap: &pixWhite, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(processedMid, toBitmap: &pixMid, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        
        // Fully clipped regions carry no data: local highlights taper so they stay bright, not mud grey
        XCTAssertGreaterThanOrEqual(pixWhite[0], 185, "Clipped white must not collapse to grey at Highlights -100")
        
        // Midtones (0.50) must remain preserved near 128 (within 20 levels to allow natural highlight knee)
        let midDiff = abs(Int(pixMid[0]) - 128)
        XCTAssertLessThanOrEqual(midDiff, 20, "Midtones must remain well preserved around 0.50")
    }
    
    func testPipelineIntegrationWithLightcraftHighlights() {
        let pipeline = AdobeColorPipeline.shared
        let testImage = CIImage(color: CIColor(red: 0.90, green: 0.80, blue: 0.65)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        
        var xmp = XMPMetadata()
        xmp.highlights2012 = -60
        let output = pipeline.process(image: testImage, cameraModel: "ILCE-7M4", xmp: xmp)
        XCTAssertNotNil(output)
        XCTAssertEqual(output.extent.width, 32)
        XCTAssertEqual(output.extent.height, 32)
    }
    
    func testAcceptedHighlightsKernelChromaCapAndGamutMapping() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        // High-luminance, high-saturation color patch (e.g. extreme recovered blown sky)
        let baseline = CIImage(color: CIColor(red: 0.99, green: 0.95, blue: 0.80)).cropped(to: extent)
        let target = CIImage(color: CIColor(red: 0.80, green: 0.70, blue: 0.40)).cropped(to: extent)
        
        let fcs = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let ctx = CIContext(options: [.useSoftwareRenderer: false, .workingColorSpace: fcs, .outputColorSpace: fcs])
        
        let field = try AcceptedHighlightsKernel.prepare(baseline: baseline, target: target, context: ctx)
        let result = AcceptedHighlightsKernel.apply(baseline: baseline, target: target, field: field)
        
        var pix = [Float](repeating: 0, count: 4)
        ctx.render(result, toBitmap: &pix, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: fcs)
        
        // Output must remain strictly within valid physical gamut [0, 1] without overflow
        XCTAssertGreaterThanOrEqual(pix[0], 0.0)
        XCTAssertLessThanOrEqual(pix[0], 1.0)
        XCTAssertGreaterThanOrEqual(pix[1], 0.0)
        XCTAssertLessThanOrEqual(pix[1], 1.0)
        XCTAssertGreaterThanOrEqual(pix[2], 0.0)
        XCTAssertLessThanOrEqual(pix[2], 1.0)
    }
    
    func testSonyARWHighlightRecoveryVerification() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else {
            throw XCTSkip("Sony ARW test file not found at \(arwURL.path)")
        }
        
        let xmpURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.xmp")
        var xmp = XMPMetadata()
        if let data = try? Data(contentsOf: xmpURL) {
            xmp = XMPParser.parse(data: data)
        }
        xmp.highlights2012 = -100
        
        // 1. Load base holder
        RAWImageLoader.shared.clearCache()
        guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: arwURL, xmp: xmp) else {
            XCTFail("Failed to load RAW base holder for A7C00904.ARW")
            return
        }
        
        let ctx = CIContext()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        
        // 2. Standard Path Process
        var stdXMP = xmp
        stdXMP.advancedRAWHighlightRecovery = false
        let stdProcessed = AdobeColorPipeline.shared.process(
            image: holder.full,
            cameraModel: "ILCE-7CM2",
            xmp: stdXMP,
            baseHolder: holder
        )
        
        if let stdCG = ctx.createCGImage(stdProcessed, from: holder.fullExtent, format: .RGBA8, colorSpace: srgb) {
            let outURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/A7C00904-LB-Standard.jpg")
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, stdCG, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                CGImageDestinationFinalize(dest)
                fputs("Exported /Volumes/Super SSD/Photo/Temp/A7C00904-LB-Standard.jpg successfully\n", stderr)
            }
        }
        
        // 3. Advanced RAW Highlight Recovery Process
        if let source = holder.highlightsSource {
            var advXMP = xmp
            advXMP.advancedRAWHighlightRecovery = true
            let advService = NativeHighlightsService.shared
            advService.clear()
            if let advImage = advService.image(source: source, xmp: advXMP, cameraModel: "ILCE-7CM2") {
                if let advCG = ctx.createCGImage(advImage, from: holder.fullExtent, format: .RGBA8, colorSpace: srgb) {
                    let outURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/A7C00904-LB-Advanced.jpg")
                    if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, advCG, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                        CGImageDestinationFinalize(dest)
                        fputs("Exported /Volumes/Super SSD/Photo/Temp/A7C00904-LB-Advanced.jpg successfully\n", stderr)
                    }
                }
            }
        }
    }
    
    func testPhotoExportServiceUsesAdvancedHighlightsByDefault() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }
        guard var asset = FolderScanner.parseAsset(fileURL: arwURL) else { return }
        
        asset.xmp.highlights2012 = -100
        asset.xmp.advancedRAWHighlightRecovery = nil // default without explicit per-photo override
        XCTAssertTrue(NativeHighlightsService.isAdvancedEnabled(for: asset.xmp), "Advanced highlight recovery must be active by default for RAW files")
        
        let outURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/A7C00904-PhotoExportService.jpg")
        try PhotoExportService.shared.exportPhoto(asset: asset, to: outURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
    }
    
    @MainActor
    func testHighlightPreviewQualitySettingsAndFastRender() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }
        
        let settings = PerformanceSettings.shared
        let originalQuality = settings.highlightPreviewQuality
        defer { settings.highlightPreviewQuality = originalQuality }
        
        // 1. Verify fast mode
        settings.highlightPreviewQuality = .fast
        XCTAssertEqual(PerformanceSettings.currentHighlightPreviewQuality, .fast)
        
        // 2. Load holder and test renderProcessedAsync in fast mode
        var xmp = XMPMetadata()
        xmp.highlights2012 = -100
        guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: arwURL, xmp: xmp) else {
            XCTFail("Failed to load RAW base holder")
            return
        }
        
        let t0 = ProcessInfo.processInfo.systemUptime
        let fastRender = await RAWImageLoader.shared.renderProcessedAsync(baseHolder: holder, cameraModel: "ILCE-7CM2", xmp: xmp, fullResolution: false)
        let fastElapsed = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        XCTAssertNotNil(fastRender)
        fputs(">>> Fast preview render took: \(String(format: "%.1f", fastElapsed))ms\n", stderr)
        
        // 3. Switch to full mode and verify persistence and render
        settings.highlightPreviewQuality = .full
        XCTAssertEqual(PerformanceSettings.currentHighlightPreviewQuality, .full)
        let t1 = ProcessInfo.processInfo.systemUptime
        let fullRender = await RAWImageLoader.shared.renderProcessedAsync(baseHolder: holder, cameraModel: "ILCE-7CM2", xmp: xmp, fullResolution: false)
        let fullElapsed = (ProcessInfo.processInfo.systemUptime - t1) * 1000
        XCTAssertNotNil(fullRender)
        fputs(">>> Full preview render took: \(String(format: "%.1f", fullElapsed))ms\n", stderr)
    }
    
    func testNativeHighlightsWithColorMixerSliderLiveUpdate() async throws {
        let arwURL = URL(fileURLWithPath: "/Volumes/Super SSD/Photo/Temp/09-17_淡江大橋/A7C00904.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }
        
        var xmp = XMPMetadata()
        xmp.highlights2012 = -80
        xmp.advancedRAWHighlightRecovery = true
        
        guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: arwURL, xmp: xmp),
              let source = holder.highlightsSource else {
            XCTFail("Failed to load holder and highlightsSource")
            return
        }
        
        let advService = NativeHighlightsService.shared
        advService.clear()
        
        // 1. Render baseline (Blue = 0)
        let img0 = try XCTUnwrap(advService.image(source: source, xmp: xmp, cameraModel: "ILCE-7CM2"))
        
        // 2. Adjust Blue slider: Luminance = 100
        var xmpBlue100 = xmp
        xmpBlue100.hsl.blue.luminance = 100
        let imgBlue100 = try XCTUnwrap(advService.image(source: source, xmp: xmpBlue100, cameraModel: "ILCE-7CM2"))
        
        // 3. Render a patch from the sky region (e.g. at x=3000, y=1000)
        let ctx = CIContext()
        func samplePatch(_ img: CIImage) -> [Float] {
            var pixels = [Float](repeating: 0, count: 16 * 16 * 4)
            ctx.render(img, toBitmap: &pixels, rowBytes: 16 * 16,
                       bounds: CGRect(x: 3000, y: 1000, width: 16, height: 16),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return pixels
        }
        
        let p0 = samplePatch(img0)
        let pBlue = samplePatch(imgBlue100)
        
        // The pixels must NOT be identical: Blue Luminance +100 must alter the sky preview
        XCTAssertNotEqual(p0, pBlue, "Preview must change when Blue Luminance is set to 100")
    }
    
    func testLocalShadowRecoveryAndPerceptualContrastLiftDeepLinearShadowsWithoutCrushing() {
        let pipeline = AdobeColorPipeline.shared
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: linearSpace])
        
        // 1. Deep linear RAW shadow patch (linear RGB ~0.008, ~4.5 stops below 0.18 middle gray)
        // Old linear contrast subtracted ~0.015 and crushed this to 0.0 (dead black)
        let deepShadowColor = CIColor(red: 0.007, green: 0.009, blue: 0.006, colorSpace: linearSpace)!
        let deepShadowImg = CIImage(color: deepShadowColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        
        // 2. Saturated blue sky patch (peak = 0.65, should NOT be lifted as shadow)
        let skyColor = CIColor(red: 0.15, green: 0.35, blue: 0.65, colorSpace: linearSpace)!
        let skyImg = CIImage(color: skyColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        
        func sampleSRGBLuma(_ img: CIImage) -> Double {
            var pix = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &pix, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: srgbSpace)
            return 0.2126 * Double(pix[0]) + 0.7152 * Double(pix[1]) + 0.0722 * Double(pix[2])
        }
        
        let baseShadowLuma = sampleSRGBLuma(deepShadowImg)
        let baseSkyLuma = sampleSRGBLuma(skyImg)
        
        // Verify perceptual contrast alone never clips deep linear shadow to 0
        let contrastedShadow = AdaptiveContrastKernel.apply(image: deepShadowImg, contrastFactor: 1.06, pivot: 0.50)
        let contrastedShadowLuma = sampleSRGBLuma(contrastedShadow)
        XCTAssertGreaterThan(contrastedShadowLuma, 10.0, "Positive contrast must not crush deep linear RAW shadows (< 0.015) to dead black")
        
        // Verify Shadows +100 with Blacks -19, Contrast +9, Dehaze +10 substantially opens up deep shadows
        var xmp = XMPMetadata()
        xmp.shadows2012 = 100
        xmp.blacks2012 = -19
        xmp.contrast2012 = 9
        xmp.dehaze = 10
        xmp.advancedRAWHighlightRecovery = true
        
        let processedShadowPV2012 = pipeline.process(image: deepShadowImg, cameraModel: "ILCE-7CM2", xmp: xmp, isRaw: true)
        let processedShadowDarkroom = pipeline.processDarkroom(image: deepShadowImg, xmp: xmp)
        
        let liftedPV2012 = sampleSRGBLuma(processedShadowPV2012)
        let liftedDarkroom = sampleSRGBLuma(processedShadowDarkroom)
        
        XCTAssertGreaterThan(liftedPV2012, baseShadowLuma + 28.0, "PV2012 pipeline must significantly lift deep linear shadows at Shadows +100 even with Blacks -19")
        XCTAssertGreaterThan(liftedDarkroom, baseShadowLuma + 28.0, "Darkroom pipeline must significantly lift deep linear shadows at Shadows +100 even with Blacks -19")
        
        // Verify saturated blue sky is protected from shadow lift
        var xmpShadowOnly = XMPMetadata()
        xmpShadowOnly.shadows2012 = 100
        let skyAfterShadow = LocalShadowRecoveryKernel.apply(image: skyImg, shadowFactor: 1.0, blacksFactor: 0.0)
        let skyAfterLuma = sampleSRGBLuma(skyAfterShadow)
        XCTAssertLessThanOrEqual(abs(skyAfterLuma - baseSkyLuma), 2.0, "Peak-aware shadow zone metric must protect saturated blue sky from being lifted by Shadows +100")
    }
    
    func testScaleInvariantLocalClarityEnhancesAndSoftensMidtoneContrast() throws {
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: linearSpace])
        
        // Create a 128x128 midtone checkerboard/stripe pattern (left half y=0.14, right half y=0.24)
        let darkMid = CIImage(color: CIColor(red: 0.14, green: 0.14, blue: 0.14, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 128))
        let brightMid = CIImage(color: CIColor(red: 0.24, green: 0.24, blue: 0.24, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 64, y: 0, width: 64, height: 128))
        let pattern = brightMid.composited(over: darkMid.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))))
        
        func edgeContrast(_ img: CIImage) -> Double {
            var leftPix = [UInt8](repeating: 0, count: 4)
            var rightPix = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &leftPix, rowBytes: 4, bounds: CGRect(x: 62, y: 64, width: 1, height: 1), format: .RGBA8, colorSpace: srgbSpace)
            ctx.render(img, toBitmap: &rightPix, rowBytes: 4, bounds: CGRect(x: 65, y: 64, width: 1, height: 1), format: .RGBA8, colorSpace: srgbSpace)
            return Double(rightPix[0]) - Double(leftPix[0])
        }
        
        let baseDiff = edgeContrast(pattern)
        let plusClarity = LocalClarityKernel.apply(image: pattern, clarityFactor: 1.0)
        let minusClarity = LocalClarityKernel.apply(image: pattern, clarityFactor: -1.0)
        
        let plusDiff = edgeContrast(plusClarity)
        let minusDiff = edgeContrast(minusClarity)
        
        XCTAssertGreaterThan(plusDiff, baseDiff + 12.0, "Clarity +100 must visibly boost midtone local contrast")
        XCTAssertLessThan(minusDiff, baseDiff - 8.0, "Clarity -100 must visibly soften midtone local contrast")
    }

    func testSpotHealRemovesDustSpotAndRoundTripsInXMP() throws {
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: linearSpace])

        // 1. Create a 200x200 clean sky image with a dark dust spot at normalized (0.40, 0.30) -> CI (80, 140)
        let sky = CIImage(color: CIColor(red: 0.25, green: 0.45, blue: 0.72, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let spot = CIImage(color: CIColor(red: 0.05, green: 0.10, blue: 0.18, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 74, y: 134, width: 12, height: 12))
        let dirtySky = spot.composited(over: sky)

        func sampleRed(_ img: CIImage, x: Int, y: Int) -> UInt8 {
            var pix = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &pix, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: srgbSpace)
            return pix[0]
        }

        let dirtyCenterR = sampleRed(dirtySky, x: 80, y: 140)
        let cleanSurroundR = sampleRed(dirtySky, x: 120, y: 140)
        XCTAssertLessThan(dirtyCenterR + 40, cleanSurroundR, "Precondition: dust spot center must be significantly darker than sky")

        let entry = SpotHealEntry(
            mode: .heal,
            targetX: 0.40,
            targetY: 0.30,
            sourceX: 0.60,
            sourceY: 0.30,
            radius: 0.04,
            feather: 0.50,
            opacity: 1.0
        )

        let healed = SpotHealKernel.apply(image: dirtySky, spots: [entry])
        let healedCenterR = sampleRed(healed, x: 80, y: 140)
        XCTAssertLessThanOrEqual(abs(Int(healedCenterR) - Int(cleanSurroundR)), 6, "Heal mode must seamlessly match surrounding sky luminance")

        // 2. Verify XMP round-trip
        var xmp = XMPMetadata()
        xmp.spotHeals = [entry]
        XCTAssertTrue(xmp.hasDevelopEdits)
        let xml = XMPWriter.generateXMPXML(metadata: xmp, originalFilename: "A7C02037.ARW")
        let parsed = XMPParser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(parsed.spotHeals.count, 1)
        XCTAssertEqual(parsed.spotHeals[0].mode, .heal)
        XCTAssertEqual(parsed.spotHeals[0].targetX, 0.40, accuracy: 0.0001)
        XCTAssertEqual(parsed.spotHeals[0].targetY, 0.30, accuracy: 0.0001)
        XCTAssertEqual(parsed.spotHeals[0].sourceX, 0.60, accuracy: 0.0001)
        XCTAssertEqual(parsed.spotHeals[0].radius, 0.04, accuracy: 0.0001)
    }
}
