import XCTest
import AppKit
@testable import LumiBase

/// Serial production API timing, not GUI event-to-present/FPS.
final class InteractiveEditingBenchmarkTests: XCTestCase {
    func testAllParametersSerialSweep() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_INTERACTIVE_RAW"],
              let output = ProcessInfo.processInfo.environment["LUMIBASE_INTERACTIVE_RESULTS"] else {
            throw XCTSkip("Set LUMIBASE_INTERACTIVE_RAW and LUMIBASE_INTERACTIVE_RESULTS")
        }
        let previous = NativeHighlightsService.isEnabled
        NativeHighlightsService.isEnabled = true
        defer { NativeHighlightsService.isEnabled = previous }
        let url = URL(fileURLWithPath: path)
        var base = XMPMetadata()
        base.temperature = 3650; base.tint = 8; base.cameraProfile = "Adobe Standard"
        let settings = base
        let edits: [(String, @Sendable (inout XMPMetadata) -> Void)] = [
            ("exposure", { $0.exposure2012 = 0.3 }), ("contrast", { $0.contrast2012 = 15 }),
            ("highlights", { $0.highlights2012 = ($0.highlights2012 ?? 0) < 0 ? -60 : 20 }),
            ("shadows", { $0.shadows2012 = 20 }), ("whites", { $0.whites2012 = 15 }),
            ("blacks", { $0.blacks2012 = -15 }), ("texture", { $0.texture = 15 }),
            ("clarity", { $0.clarity2012 = 15 }), ("dehaze", { $0.dehaze = 15 }),
            ("vibrance", { $0.vibrance = 15 }), ("saturation", { $0.saturation = 15 }),
            ("temperature", { $0.temperature = 4150 }), ("tint", { $0.tint = 18 })]
        var rows: [[String: Any]] = []
        for trial in 0..<3 {
            for highlight in [0, -80] {
                for mode in ["Fit", "ROI"] {
                    for (parameter, edit) in edits {
                        var initial = settings; initial.highlights2012 = highlight
                        RAWImageLoader.shared.clearCache()
                        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: url, xmp: initial)
                        let holder = try XCTUnwrap(loaded)
                        let roi = CGRect(x: holder.fullExtent.midX - 508, y: holder.fullExtent.midY - 429, width: 1016, height: 858)
                        _ = await Task.detached { RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: initial, interactive: true, fullResolution: mode == "ROI", sourceRect: mode == "ROI" ? roi : nil) }.value
                        var changed = initial; edit(&changed)
                        let target = changed
                        let start = ProcessInfo.processInfo.systemUptime
                        let next = await RAWImageLoader.shared.loadBaseHolder(from: url, xmp: target)
                        let nextHolder = try XCTUnwrap(next)
                        let decodeMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        let before = NativeHighlightsService.shared.statistics
                        let renderStart = ProcessInfo.processInfo.systemUptime
                        let image = await Task.detached { RAWImageLoader.shared.renderProcessed(baseHolder: nextHolder, cameraModel: nil, xmp: target, interactive: true, fullResolution: mode == "ROI", sourceRect: mode == "ROI" ? roi : nil) }.value
                        let cg = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                        let bytes = try XCTUnwrap(cg.dataProvider?.data)
                        let renderMs = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
                        let after = NativeHighlightsService.shared.statistics
                        rows.append(["trial": trial, "highlights": highlight, "mode": mode, "parameter": parameter,
                            "decodeMs": decodeMs, "renderMs": renderMs, "totalMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                            "preparations": after.preparations - before.preparations,
                            "preparationMs": after.preparations > before.preparations ? after.preparationMilliseconds : 0,
                            "bytes": CFDataGetLength(bytes)])
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        XCTAssertEqual(rows.count, 156)
    }
}
