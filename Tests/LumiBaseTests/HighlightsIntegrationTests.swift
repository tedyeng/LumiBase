import XCTest
import CoreImage
@testable import LumiBase

final class HighlightsIntegrationTests: XCTestCase {
    // The calibrated fixture is private; supply its read-only location explicitly.
    static let source = ProcessInfo.processInfo.environment["LUMIBASE_HIGHLIGHTS_DNG"].map {
        URL(fileURLWithPath: $0)
    } ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/accepted-highlights.dng")
    func testEveryDevelopSettingInvalidatesGlobalFieldIdentity() throws {
        let dir = inspectionTestScratchURL("highlight-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("source.dng")
        try Data([1]).write(to: file)
        let recipe = try XCTUnwrap(HighlightsSourceRecipe(url: file))
        let initial = XMPMetadata(highlights2012: -80)
        let key = NativeHighlightsService.Key(source: recipe, xmp: initial, cameraModel: "camera")
        let mutations: [(inout XMPMetadata) -> Void] = [
            { $0.exposure2012 = 1 }, { $0.temperature = 4000 }, { $0.tint = 9 },
            { $0.contrast2012 = 1 }, { $0.highlights2012 = -40 }, { $0.shadows2012 = 1 },
            { $0.whites2012 = 1 }, { $0.blacks2012 = 1 }, { $0.dehaze = 1 },
            { $0.vibrance = 1 }, { $0.saturation = 1 }, { $0.clarity2012 = 1 },
            { $0.texture = 1 }, { $0.hasCrop = true }, { $0.cameraProfile = "Other" },
            { $0.convertToGrayscale = true }
        ]
        for mutate in mutations {
            var changed = initial; mutate(&changed)
            XCTAssertNotEqual(key, NativeHighlightsService.Key(source: recipe, xmp: changed, cameraModel: "camera"))
        }
        XCTAssertNotEqual(key, NativeHighlightsService.Key(source: recipe, xmp: initial, cameraModel: "other"))
        try Data([1, 2]).write(to: file)
        XCTAssertFalse(recipe.isCurrent)
        let changedSource = try XCTUnwrap(HighlightsSourceRecipe(url: file))
        XCTAssertNotEqual(key, NativeHighlightsService.Key(source: changedSource, xmp: initial, cameraModel: "camera"))
    }

    func testNeutralDomainInvalidatesCacheAndPreservesAcceptedAnchor() async throws {
        guard let recipe = HighlightsSourceRecipe(url: Self.source) else { throw XCTSkip("Acceptance DNG unavailable") }
        try await Task.detached {
            let service = NativeHighlightsService()
            var xmp = XMPMetadata(exposure2012: 1, temperature: 3650, tint: 8, highlights2012: -1)
            XCTAssertNotEqual(NativeHighlightsService.Key(source: recipe, xmp: xmp, cameraModel: nil),
                              NativeHighlightsService.Key(source: recipe, xmp: xmp, cameraModel: nil, neutralDomain: .nativeRAWExport))
            let preview = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil))
            _ = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.hits, 1)
            let exported = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil, neutralDomain: .nativeRAWExport))
            XCTAssertEqual(service.statistics.preparations, 2)
            XCTAssertEqual(service.statistics.entries, 1)
            func pixels(_ image: CIImage) -> [Float] {
                var p = [Float](repeating: 0, count: 64 * 64 * 4)
                service.renderContext.render(image, toBitmap: &p, rowBytes: 64 * 16,
                    bounds: CGRect(x: 4400, y: 2400, width: 64, height: 64), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
                return p
            }
            XCTAssertNotEqual(pixels(preview), pixels(exported), "Nonzero EV neutral domains must not alias")
            _ = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.preparations, 3, "Returning to preview must evict export")
            xmp.highlights2012 = -80
            let previewAnchor = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil))
            let exportAnchor = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil, neutralDomain: .nativeRAWExport))
            XCTAssertEqual(pixels(previewAnchor), pixels(exportAnchor), "Neutral domain must not alter accepted B")
        }.value
    }

    func testStrengthPolicyAndMainThreadPreparationRefusal() throws {
        XCTAssertEqual(NativeHighlightsService.strength(0), 0)
        XCTAssertEqual(NativeHighlightsService.strength(20), 0)
        XCTAssertEqual(NativeHighlightsService.strength(-1), 0.0125)
        XCTAssertEqual(NativeHighlightsService.strength(-40), 0.5)
        XCTAssertEqual(NativeHighlightsService.strength(-80), 1)
        XCTAssertEqual(NativeHighlightsService.strength(-100), 1.25)
        let service = NativeHighlightsService()
        service.clear()
        XCTAssertEqual(service.statistics.entries, 0)
        if Thread.isMainThread, let recipe = HighlightsSourceRecipe(url: Self.source) {
            XCTAssertNil(service.image(source: recipe, xmp: XMPMetadata(highlights2012: -80), cameraModel: nil))
            XCTAssertEqual(service.statistics.preparations, 0)
        }
    }

    func testCancelledPreparationDoesNotPublish() async throws {
        guard let recipe = HighlightsSourceRecipe(url: Self.source) else { throw XCTSkip("Acceptance DNG unavailable") }
        let service = NativeHighlightsService()
        let work = Task.detached {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return service.image(source: recipe, xmp: XMPMetadata(highlights2012: -80), cameraModel: nil)
        }
        work.cancel()
        let result = await work.value
        XCTAssertNil(result)
        XCTAssertEqual(service.statistics.entries, 0)
        XCTAssertEqual(service.statistics.preparations, 0)
    }

    func testNegativeStrengthContinuityAtNonzeroExposure() async throws {
        guard FileManager.default.fileExists(atPath: Self.source.path) else { throw XCTSkip("Acceptance DNG unavailable") }
        var settings = XMPMetadata(exposure2012: 0, temperature: 3650, tint: 8, highlights2012: 0)
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: Self.source, xmp: settings, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        let recipe = try XCTUnwrap(holder.highlightsSource)
        for ev in [-1.0, 1.0] {
            settings.exposure2012 = ev
            let zeroSettings = settings
            try await Task.detached {
                let context = NativeHighlightsService.shared.renderContext
                let baseline = AdobeColorPipeline.shared.process(image: holder.full, cameraModel: nil, xmp: zeroSettings, baseHolder: holder)
                var negative = zeroSettings; negative.highlights2012 = -1
                let image = try XCTUnwrap(NativeHighlightsService.shared.image(source: recipe, xmp: negative, cameraModel: nil))
                let roi = CGRect(x: 4400, y: 2400, width: 64, height: 64)
                var zero = [Float](repeating: 0, count: 64 * 64 * 4), minusOne = zero
                let color = CGColorSpace(name: CGColorSpace.linearSRGB)!
                context.render(baseline, toBitmap: &zero, rowBytes: 64 * 16, bounds: roi, format: .RGBAf, colorSpace: color)
                context.render(image, toBitmap: &minusOne, rowBytes: 64 * 16, bounds: roi, format: .RGBAf, colorSpace: color)
                let error = zero.indices.filter { $0 % 4 != 3 }.map { abs(min(1, max(0, zero[$0])) - minusOne[$0]) }.max() ?? 0
                XCTAssertLessThan(error, 0.014, "Near-zero highlight continuity at EV \(ev)")
            }.value
        }
    }

    func testNativeFaceAndHandsMatchAcceptedB() async throws {
        guard FileManager.default.fileExists(atPath: Self.source.path) else { throw XCTSkip("Acceptance DNG unavailable") }
        let xmp = XMPMetadata(exposure2012: 0, temperature: 3650, tint: 8, contrast2012: 0, highlights2012: -80, shadows2012: 0, whites2012: 0, blacks2012: 0, dehaze: 0, vibrance: 0, saturation: 0, clarity2012: 0, texture: 0, cameraProfile: "Adobe Standard")
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: Self.source, xmp: xmp, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        let rendered = await Task.detached {
            RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: xmp, fullResolution: true)
        }.value
        let image = try XCTUnwrap(rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let ci = CIImage(cgImage: image)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let samples: [(Int, Int, [Float])] = [
            (4600, 2900, [0.25795245, 0.06697012, 0.01031315]),
            (4700, 3000, [0.37184018, 0.12262741, 0.03867241]),
            (4100, 3700, [0.65631735, 0.65631735, 0.65631735]),
            (5000, 4000, [0.51188958, 0.24830714, 0.10599685])
        ]
        for (x, y, expected) in samples {
            var rgba = [Float](repeating: 0, count: 4)
            context.render(ci, toBitmap: &rgba, rowBytes: 16,
                bounds: CGRect(x: x, y: image.height - 1 - y, width: 1, height: 1),
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
            for c in 0..<3 { XCTAssertEqual(rgba[c], expected[c], accuracy: 0.007, "Accepted B at \(x),\(y) channel \(c)") }
        }
    }
}
