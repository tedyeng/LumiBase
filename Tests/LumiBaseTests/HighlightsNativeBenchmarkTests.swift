import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class HighlightsNativeBenchmarkTests: XCTestCase {
    func testIntegratedParityContinuityAndSerialBenchmarks() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_HIGHLIGHTS_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in real DNG native highlights benchmark") }
        let output = inspectionTestScratchURL("highlights-integrated-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = HighlightsIntegrationTests.source
        let xmp = XMPMetadata(exposure2012: 0, temperature: 3650, tint: 8, contrast2012: 0, highlights2012: -80, shadows2012: 0, whites2012: 0, blacks2012: 0, dehaze: 0, vibrance: 0, saturation: 0, clarity2012: 0, texture: 0, cameraProfile: "Adobe Standard")
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: source, xmp: xmp, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        let recipe = try XCTUnwrap(holder.highlightsSource)
        try await Task.detached {
            let context = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAf])
            let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let service = NativeHighlightsService.shared
            var rows: [[String: Any]] = []
            let clock = { ProcessInfo.processInfo.systemUptime }
            for trial in 0..<3 {
                service.clear()
                let start = clock()
                _ = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil))
                rows.append(["mode": "prepare", "trial": trial, "ms": (clock() - start) * 1000])
                for mode in ["Fit1440", "Fit2560", "ROI", "Full"] {
                    for repetition in 0..<4 {
                        try autoreleasepool {
                            let start = clock()
                            let image = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil,
                                xmp: xmp, interactive: mode == "Fit1440", fullResolution: mode == "ROI" || mode == "Full",
                                sourceRect: mode == "ROI" ? CGRect(x: 4088, y: 2142, width: 1016, height: 858) : nil))
                            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                            let data = try XCTUnwrap(cg.dataProvider?.data)
                            let count = CFDataGetLength(data)
                            let bytes = CFDataGetBytePtr(data)!
                            var checksum: UInt64 = 0
                            for i in stride(from: 0, to: count, by: 4096) { checksum &+= UInt64(bytes[i]) }
                            rows.append(["mode": mode, "trial": trial, "repetition": repetition,
                                "ms": (clock() - start) * 1000, "bytes": count, "checksum": checksum])
                        }
                    }
                }
            }
            if ProcessInfo.processInfo.environment["LUMIBASE_HIGHLIGHTS_TIMING_ONLY"] == "1" {
                let stats = service.statistics
                rows.append(["mode": "cache", "entries": stats.entries, "preparations": stats.preparations, "hits": stats.hits])
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("integrated-lean-timings.json"))
                print("HIGHLIGHTS_LEAN_TIMING_RESULTS \(output.path)")
                return
            }
            let native = try XCTUnwrap(service.image(source: recipe, xmp: xmp, cameraModel: nil))
            let extent = holder.fullExtent
            let width = Int(extent.width), height = Int(extent.height)
            var full = [Float](repeating: 0, count: width * height * 4)
            context.render(native, toBitmap: &full, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linear)
            try full.withUnsafeBytes { try Data($0).write(to: output.appendingPathComponent("integrated-full-linear-rgba.f32")) }
            for (name, roi) in [("face", CGRect(x: 4088, y: 2142, width: 1016, height: 858)),
                                ("hands", CGRect(x: 3604, y: 874, width: 2130, height: 1366)),
                                ("edge", CGRect(x: 0, y: 0, width: 137, height: 93))] {
                let rw = Int(roi.width), rh = Int(roi.height)
                var pixels = [Float](repeating: 0, count: rw * rh * 4)
                context.render(native, toBitmap: &pixels, rowBytes: rw * 16, bounds: roi, format: .RGBAf, colorSpace: linear)
                var maxError: Float = 0
                for y in 0..<rh { for x in 0..<rw { for c in 0..<3 {
                    // CI renders bitmap rows top-down, even though bounds use bottom-left coordinates.
                    maxError = max(maxError, abs(pixels[(y * rw + x) * 4 + c] - full[((y + height - Int(roi.maxY)) * width + x + Int(roi.minX)) * 4 + c]))
                } } }
                rows.append(["mode": "ROI-parity", "region": name, "maxLinearError": maxError])
                XCTAssertLessThan(maxError, 0.003, "Native ROI must match native full")
            }
            full.removeAll()
            let sampleROI = CGRect(x: 4400, y: 2400, width: 64, height: 64)
            var strengthPixels: [Int: [Float]] = [:]
            for h in [0, -1, -40, -80, -100, 40] {
                var settings = xmp; settings.highlights2012 = h
                let image: CIImage
                if h < 0 { image = try XCTUnwrap(service.image(source: recipe, xmp: settings, cameraModel: nil)) }
                else { image = AdobeColorPipeline.shared.process(image: holder.full, cameraModel: nil, xmp: settings, baseHolder: holder) }
                var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
                context.render(image, toBitmap: &pixels, rowBytes: 64 * 16, bounds: sampleROI, format: .RGBAf, colorSpace: linear)
                strengthPixels[h] = pixels
                let mean = pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }.reduce(0, +) / Double(64 * 64 * 3)
                rows.append(["mode": "strength", "highlight": h, "meanLinearRGB": mean])
                if h == 0 || h == 40 {
                    let actual = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: settings, fullResolution: true))
                    let actualCG = try XCTUnwrap(actual.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    let legacyContext = CIContext(options: [.useSoftwareRenderer: false, .highQualityDownsample: true])
                    let expectedCG = try XCTUnwrap(legacyContext.createCGImage(image, from: holder.fullExtent, format: .RGBA8, colorSpace: srgb, deferred: false))
                    XCTAssertEqual(actualCG.dataProvider?.data as Data?, expectedCG.dataProvider?.data as Data?, "Zero/positive must remain full-frame byte-identical")
                }
            }
            let zero = strengthPixels[0]!, one = strengthPixels[-1]!, anchor = strengthPixels[-80]!
            let half = strengthPixels[-40]!
            var linearity: Float = 0
            var nearZero: Float = 0
            for i in zero.indices where i % 4 != 3 {
                let displayZero = min(1, max(0, zero[i]))
                linearity = max(linearity, abs(half[i] - (displayZero + anchor[i]) / 2))
                nearZero = max(nearZero, abs(one[i] - displayZero))
            }
            XCTAssertLessThan(linearity, 0.003)
            XCTAssertLessThan(nearZero, 0.013)
            rows.append(["mode": "continuity", "halfMaxError": linearity, "minus1MaxDelta": nearZero])
            let exportURL = output.appendingPathComponent("integrated-Hminus80.jpg")
            let exportStart = clock()
            let asset = PhotoAsset(fileURL: source, xmp: xmp)
            try PhotoExportService.shared.exportPhoto(asset: asset, to: exportURL, quality: 1)
            rows.append(["mode": "actual-export", "ms": (clock() - exportStart) * 1000])
            let exported = try XCTUnwrap(CIImage(contentsOf: exportURL))
            XCTAssertEqual(exported.extent.size, holder.fullExtent.size)
            let exportROI = CGRect(x: 4088, y: 2142, width: 1016, height: 858)
            var jpegPixels = [Float](repeating: 0, count: 1016 * 858 * 4)
            var referencePixels = jpegPixels
            context.render(exported, toBitmap: &jpegPixels, rowBytes: 1016 * 16, bounds: exportROI, format: .RGBAf, colorSpace: linear)
            context.render(native, toBitmap: &referencePixels, rowBytes: 1016 * 16, bounds: exportROI, format: .RGBAf, colorSpace: linear)
            var jpegError = 0.0
            for i in jpegPixels.indices where i % 4 != 3 { jpegError += Double(abs(jpegPixels[i] - referencePixels[i])) }
            jpegError /= Double(1016 * 858 * 3)
            XCTAssertLessThan(jpegError, 0.007, "Export and preview must use the same prepared global native graph, allowing JPEG quantization")
            rows.append(["mode": "export-parity", "faceMeanLinearError": jpegError])
            let stats = service.statistics
            rows.append(["mode": "cache", "entries": stats.entries, "preparations": stats.preparations, "hits": stats.hits,
                         "lastPreparationMs": stats.preparationMilliseconds])
            XCTAssertEqual(stats.entries, 1)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("integrated-timings-parity.json"))
            print("HIGHLIGHTS_INTEGRATED_RESULTS \(output.path)")
        }.value
    }
}
