import XCTest
import AppKit
@testable import LumiBase

final class InteractiveBurstBenchmarkTests: XCTestCase {
    @MainActor func testRAWLatestWinsBurst() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_INTERACTIVE_RAW"],
              let output = ProcessInfo.processInfo.environment["LUMIBASE_BURST_RESULTS"] else { throw XCTSkip("Opt-in RAW queue experiment") }
        let previous = NativeHighlightsService.isEnabled
        NativeHighlightsService.isEnabled = true
        defer { NativeHighlightsService.isEnabled = previous }
        var rows: [[String: Any]] = []
        for trial in 0..<3 { for highlights in [0, -80] { for native in [false, true] {
            RAWImageLoader.shared.clearCache()
            let initial = XMPMetadata(temperature: 3650, tint: 8, highlights2012: highlights, cameraProfile: "Adobe Standard")
            let loaded = await RAWImageLoader.shared.loadBaseHolder(from: URL(fileURLWithPath: path), xmp: initial)
            let holder = try XCTUnwrap(loaded)
            let rect = native ? CGRect(x: holder.fullExtent.midX - 508, y: holder.fullExtent.midY - 429, width: 1016, height: 858) : nil
            let warm = await Task.detached { RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: initial, interactive: true, fullResolution: native, sourceRect: rect) }.value
            XCTAssertNotNil(warm)
            let engine = LiveDevelopPreviewEngine()
            let done = expectation(description: "final raster callback")
            var actual: NSImage?
            let begin = ProcessInfo.processInfo.systemUptime
            for index in 1...30 {
                var xmp = initial; xmp.exposure2012 = Double(index) / 30
                engine.requestRender(baseHolder: holder, cameraModel: nil, xmp: xmp, interactive: true, fullResolution: native, sourceRect: rect) { image in
                    if index == 30 { actual = image; done.fulfill() }
                }
                if index != 30 { try await Task.sleep(nanoseconds: 8_000_000) }
            }
            await fulfillment(of: [done], timeout: 20)
            let stats = engine.statistics
            let prep = NativeHighlightsService.shared.statistics
            rows.append(["trial": trial, "highlights": highlights, "mode": native ? "ROI" : "Fit", "submitted": stats.submitted,
                         "started": stats.started, "coalesced": stats.coalesced, "discarded": stats.discarded, "published": stats.published,
                         "lastQueueMs": stats.lastQueueMilliseconds, "lastRenderMs": stats.lastRenderMilliseconds,
                         "lastEnqueueToCallbackMs": stats.lastCallbackMilliseconds, "burstToFinalCallbackMs": (ProcessInfo.processInfo.systemUptime - begin) * 1000,
                         "lastPreparationMs": prep.preparationMilliseconds])
            var final = initial; final.exposure2012 = 1
            let referenceSettings = final
            let reference = await Task.detached { RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: referenceSettings, interactive: true, fullResolution: native, sourceRect: rect) }.value
            let actualCG = try XCTUnwrap(actual?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let referenceCG = try XCTUnwrap(reference?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(actualCG.dataProvider?.data as Data?, referenceCG.dataProvider?.data as Data?, "Final coalesced frame must match exact final settings")
            XCTAssertEqual(stats.submitted, stats.started + stats.coalesced)
        } } }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        XCTAssertEqual(rows.count, 12)
    }
}
