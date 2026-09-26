import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
@testable import LumiBase

final class HighlightsToggleRefreshTests: XCTestCase {
    @MainActor func testSameNegativeRAWChangesPixelsWhenAdvancedSwitchChanges() async throws {
        let source = HighlightsIntegrationTests.source
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("RAW fixture unavailable") }
        let xmp = XMPMetadata(temperature: 3650, tint: 8, highlights2012: -80)
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: source, xmp: xmp, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        let previous = NativeHighlightsService.isEnabled
        defer { NativeHighlightsService.isEnabled = previous }
        NativeHighlightsService.isEnabled = false
        let standard = await Task.detached {
            RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil,
                xmp: xmp, interactive: true)
        }.value
        NativeHighlightsService.isEnabled = true
        let advanced = await Task.detached {
            RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil,
                xmp: xmp, interactive: true)
        }.value
        let a = try XCTUnwrap(standard?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try XCTUnwrap(advanced?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?,
                          "A real negative-Highlights RAW must switch rendering policy without an XMP edit")
    }

    @MainActor func testHostedLoupeRequestsNewRasterAfterToggle() async throws {
        let url = inspectionTestScratchURL("toggle-host-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        let ci = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: rect)
        let cg = try XCTUnwrap(CIContext().createCGImage(ci, from: rect))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let asset = PhotoAsset(fileURL: url, xmp: XMPMetadata(highlights2012: -80))
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]
        state.primarySelectedAssetID = asset.id
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        host.layoutSubtreeIfNeeded()
        let before = LiveDevelopPreviewEngine.shared.statistics.submitted
        let previous = state.isNativeHighlightsEnabled
        defer { state.isNativeHighlightsEnabled = previous }
        state.isNativeHighlightsEnabled = !previous
        try await Task.sleep(nanoseconds: 700_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(LiveDevelopPreviewEngine.shared.statistics.submitted, before)
        XCTAssertNil(state.liveDevelopXMP)
        XCTAssertEqual(state.allAssets[0].xmp, asset.xmp)
    }

    @MainActor func testNativeROICacheIdentityIncludesHighlightPolicy() {
        let previous = NativeHighlightsService.isEnabled
        defer { NativeHighlightsService.isEnabled = previous }
        let settings = XMPMetadata(highlights2012: -80)
        NativeHighlightsService.isEnabled = false
        let standard = ProcessedROIRequest.settingsIdentity(settings)
        NativeHighlightsService.isEnabled = true
        let advanced = ProcessedROIRequest.settingsIdentity(settings)
        XCTAssertNotEqual(standard, advanced)
    }

    @MainActor func testToggleInvalidatesRenderWithoutEditingXMP() throws {
        let state = AppState()
        let asset = PhotoAsset(fileURL: inspectionTestScratchURL("toggle-\(UUID().uuidString).dng"),
                               xmp: XMPMetadata(highlights2012: -80))
        state.allAssets = [asset]
        state.primarySelectedAssetID = asset.id
        let original = state.allAssets[0].xmp
        let previous = state.isNativeHighlightsEnabled
        defer { state.isNativeHighlightsEnabled = previous }
        let oldRevision = state.highlightsRenderRevision
        state.isNativeHighlightsEnabled = !previous
        XCTAssertNotEqual(state.highlightsRenderRevision, oldRevision)
        XCTAssertEqual(state.allAssets[0].xmp, original)
        XCTAssertNil(state.liveDevelopXMP)
        XCTAssertEqual(NativeHighlightsService.isEnabled, !previous)
    }
}
