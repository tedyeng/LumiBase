import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
@testable import LumiBase

final class InspectionDoubleClickTests: XCTestCase {
    @MainActor func testActualLoupeDoubleClickReplacesOffCenterROIWithoutDrag() async throws {
        try await exerciseDoubleClick(x: 190, settleBetweenPresses: true)
    }
    @MainActor func testActualLoupeRightSideDoubleClickReplacesROIWithoutDrag() async throws {
        try await exerciseDoubleClick(x: 570, settleBetweenPresses: true)
    }
    @MainActor func testActualLoupeFastDoubleClickCoalescingDoesNotLeaveBlackROI() async throws {
        try await exerciseDoubleClick(x: 190, settleBetweenPresses: false)
    }
    @MainActor private func exerciseDoubleClick(x: CGFloat, settleBetweenPresses: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roi-double-click-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("coverage.tiff")
        let extent = CGRect(x: 0, y: 0, width: 8192, height: 5464)
        let cg = try XCTUnwrap(CIContext().createCGImage(CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.3)).cropped(to: extent), from: extent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let asset = PhotoAsset(fileURL: url)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.isFilmstripVisible = false
        state.allAssets = [asset]
        state.primarySelectedAssetID = asset.id
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle(_ ms: UInt64) async throws {
            try await Task.sleep(nanoseconds: ms * 1_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try await settle(1500)
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let surface = try XCTUnwrap(descendants(host).compactMap { $0 as? InspectionSurface.Surface }.first)
        func event(_ type: NSEvent.EventType, count: Int, time: Double) throws -> NSEvent {
            let point = surface.convert(CGPoint(x: x, y: 270), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: 1))
        }
        func coverage() throws -> Int {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            // Central horizontal scan, clear of HUD/controls. A solid source must cover it.
            let samples = stride(from: rep.pixelsWide / 10, to: rep.pixelsWide * 9 / 10, by: max(1, rep.pixelsWide / 40))
            return samples.filter { x in
                guard let c = rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
                return c.greenComponent > 0.15
            }.count
        }
        XCTAssertGreaterThan(try coverage(), 28, "fixture must be visible before input")
        surface.mouseDown(with: try event(.leftMouseDown, count: 1, time: 1))
        if settleBetweenPresses { try await settle(150) }
        surface.mouseUp(with: try event(.leftMouseUp, count: 1, time: 1.16))
        if settleBetweenPresses { try await settle(50) }
        surface.mouseDown(with: try event(.leftMouseDown, count: 2, time: 1.22))
        if settleBetweenPresses { try await settle(150) }
        surface.mouseUp(with: try event(.leftMouseUp, count: 2, time: 1.38))
        try await settle(1500)
        let covered = try coverage()
        print("DOUBLE_CLICK_COVERAGE x=\(x) settled=\(settleBetweenPresses) before-drag=\(covered)/32")
        XCTAssertGreaterThan(covered, 28, "persistent 100% must replace the off-center held ROI without requiring a drag")
    }
}
