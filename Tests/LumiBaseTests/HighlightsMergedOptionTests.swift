import XCTest
@testable import LumiBase

final class HighlightsMergedOptionTests: XCTestCase {
    func testExperimentalSwitchControlsNativeRAWSelection() async throws {
        let source = HighlightsIntegrationTests.source
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("RAW fixture unavailable") }
        let xmp = XMPMetadata(highlights2012: -80)
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: source, xmp: xmp, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        let previous = NativeHighlightsService.isEnabled
        defer { NativeHighlightsService.isEnabled = previous }
        NativeHighlightsService.isEnabled = false
        XCTAssertFalse(NativeHighlightsService.applies(holder: holder, xmp: xmp))
        NativeHighlightsService.isEnabled = true
        XCTAssertTrue(NativeHighlightsService.applies(holder: holder, xmp: xmp))
    }

    func testEditedNegativeRAWThumbnailNeverPreparesFullNativeField() async throws {
        let source = HighlightsIntegrationTests.source
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("RAW fixture unavailable") }
        let previous = NativeHighlightsService.isEnabled
        NativeHighlightsService.isEnabled = true
        defer { NativeHighlightsService.isEnabled = previous }
        let before = NativeHighlightsService.shared.statistics.preparations
        let xmp = XMPMetadata(contrast2012: 11, highlights2012: -80)
        let asset = PhotoAsset(fileURL: source, dateModified: Date(), xmp: xmp)
        let thumbnail = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 320)
        let image = try XCTUnwrap(thumbnail)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 320)
        XCTAssertEqual(NativeHighlightsService.shared.statistics.preparations, before)
    }
}
