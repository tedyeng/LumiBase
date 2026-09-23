import XCTest
import AppKit
import CoreImage
@testable import LumiBase

final class InspectionTests: XCTestCase {
    func testCachedROITransitionWaitsForHolderThenRequestsFullFitWithoutReplacingNativeROI() {
        var transition = InspectionCachedROITransition()
        var display = InspectionDisplay()
        let ticket = display.beginSelection(assetID: "cached-selection", filename: "selected.dng")
        let cachedROI = NSImage(size: NSSize(width: 900, height: 700))
        let fullExtent = CGRect(x: 0, y: 0, width: 6000, height: 4000)
        display.accept(cachedROI, assetID: "cached-selection", filename: "selected.dng", pixels: cachedROI.size,
                       native: true, ticket: ticket, sourceRect: CGRect(x: 2500, y: 1600, width: 900, height: 700), fullExtent: fullExtent)
        XCTAssertTrue(transition.publishCachedROI())
        XCTAssertTrue(transition.keepsCachedROIWhilePreparing)
        XCTAssertTrue(transition.needsBaseHolder)
        transition.requestFit()
        XCTAssertEqual(transition.baseHolderPrepared(isZoomed: false), .renderFullFit)
        XCTAssertFalse(transition.keepsCachedROIWhilePreparing)
        XCTAssertFalse(transition.needsBaseHolder)
        XCTAssertTrue(display.image === cachedROI, "holder preparation keeps the selected native ROI visible until a full Fit result arrives")
        XCTAssertNotNil(display.sourceRect, "the cached partial region retains its native ROI provenance")
        let fullFit = NSImage(size: NSSize(width: 1600, height: 1066))
        display.accept(fullFit, assetID: "cached-selection", filename: "selected.dng", pixels: fullExtent.size,
                       native: false, ticket: ticket, fullExtent: fullExtent)
        XCTAssertTrue(display.image === fullFit)
        XCTAssertNil(display.sourceRect)

        var stillZoomed = InspectionCachedROITransition()
        _ = stillZoomed.publishCachedROI()
        XCTAssertEqual(stillZoomed.baseHolderPrepared(isZoomed: true), .keepCachedNativeROI)

        var holderFailure = InspectionCachedROITransition()
        _ = holderFailure.publishCachedROI()
        holderFailure.requestFit()
        XCTAssertEqual(holderFailure.baseHolderFailed(), .loadFullFitPreview)
        var nativeDisplay = InspectionDisplay()
        let nativeTicket = nativeDisplay.beginSelection(assetID: "native-selection", filename: "native.dng")
        nativeDisplay.accept(cachedROI, assetID: "native-selection", filename: "native.dng", pixels: cachedROI.size,
                             native: true, ticket: nativeTicket, sourceRect: CGRect(x: 2500, y: 1600, width: 900, height: 700), fullExtent: fullExtent)
        XCTAssertTrue(nativeDisplay.image === cachedROI, "an async full preview fallback is cached without replacing the native ROI")
        XCTAssertNotNil(nativeDisplay.sourceRect)
    }

    func testCachedROIHolderWarmupCompletesPreviewSelectionWhenStillZoomed() {
        var stillZoomed = InspectionCachedROITransition()
        XCTAssertTrue(stillZoomed.publishCachedROI())
        XCTAssertEqual(stillZoomed.baseHolderPrepared(isZoomed: true), .keepCachedNativeROI)
        XCTAssertTrue(stillZoomed.shouldCompletePreviewSelectionAfterHolderPreparation(isZoomed: true),
                      "completed holder warmup while still zoomed must release the PreviewPreloader selection owner")

        var fitRequested = InspectionCachedROITransition()
        XCTAssertTrue(fitRequested.publishCachedROI())
        fitRequested.requestFit()
        XCTAssertEqual(fitRequested.baseHolderPrepared(isZoomed: false), .renderFullFit)
        XCTAssertFalse(fitRequested.shouldCompletePreviewSelectionAfterHolderPreparation(isZoomed: false),
                       "a pending Fit render retains foreground ownership until that render completes")
    }

    func testForegroundOwnerCleanupUsesCurrentTokenAndRejectsStaleRelease() {
        var lifecycle = InspectionROIForegroundLifecycle()
        let selectionToken = UUID().uuidString
        lifecycle.begin(selectionToken)
        // The unsupported-native path runs before a render token is started.
        XCTAssertEqual(lifecycle.activeOwner, selectionToken)
        XCTAssertEqual(lifecycle.finish(selectionToken), selectionToken)
        XCTAssertNil(lifecycle.activeOwner)

        let failedDecodeSelection = UUID().uuidString
        lifecycle.begin(failedDecodeSelection)
        XCTAssertEqual(lifecycle.finish(failedDecodeSelection), failedDecodeSelection,
                       "the no-holder/decode-failure path releases its selection owner")
        let roiOffRender = UUID().uuidString
        lifecycle.begin(roiOffRender)
        XCTAssertEqual(lifecycle.finish(roiOffRender), roiOffRender, "ROI OFF render completion releases its render owner")

        let secondSelection = UUID().uuidString
        let renderToken = UUID().uuidString
        lifecycle.begin(secondSelection)
        lifecycle.begin(renderToken)
        XCTAssertNil(lifecycle.finish(secondSelection), "a stale selection completion cannot release the newer render owner")
        XCTAssertEqual(lifecycle.activeOwner, renderToken)
        XCTAssertEqual(lifecycle.finishCurrent(), renderToken, "onDisappear releases the active owner")
        XCTAssertNil(lifecycle.activeOwner)
        XCTAssertNil(lifecycle.finishCurrent(), "the no-selection path has no owner left to release")
    }

    func testROINativeReleaseToFitRestoresFullFrameAndUsesFullExtentSizing() throws {
        var display = InspectionDisplay()
        let ticket = display.begin(filename: "photo.dng")
        let full = NSImage(size: NSSize(width: 6000, height: 4000))
        let roi = NSImage(size: NSSize(width: 1200, height: 900))
        let extent = CGRect(x: 100, y: 200, width: 6000, height: 4000)
        display.accept(full, filename: "photo.dng", pixels: extent.size, native: false, ticket: ticket, fullExtent: extent)
        display.accept(roi, filename: "photo.dng", pixels: roi.size, native: true, ticket: ticket,
                       sourceRect: CGRect(x: 2500, y: 1700, width: 1200, height: 900), fullExtent: extent)
        XCTAssertFalse(InspectionFrameLayout.canReuseNativeFrame(isNative: display.native, isROI: display.sourceRect != nil, zoomed: false))
        InspectionFrameLayout.leaveNative(display: &display)
        XCTAssertTrue(display.image === full)
        XCTAssertNil(display.sourceRect)
        XCTAssertEqual(display.fullExtent, extent)
        let fit = InspectionFrameLayout.make(pixels: display.pixels, sourceRect: display.sourceRect,
                                             fullExtent: display.fullExtent, zoomed: false,
                                             viewport: CGSize(width: 1000, height: 700), backing: 2)
        XCTAssertEqual(fit.imageSize.width, 1000, accuracy: 0.01)
        XCTAssertEqual(fit.imageSize.height, 666.666, accuracy: 0.01)
    }

    func testPersistentToggleOffCannotReuseROIAsFullNativeFrame() throws {
        var state = InspectionState(); state.persistent = true
        var display = InspectionDisplay()
        let ticket = display.begin(filename: "persistent.dng")
        let full = NSImage(size: NSSize(width: 8000, height: 6000))
        display.accept(full, filename: "persistent.dng", pixels: full.size, native: true, ticket: ticket,
                       fullExtent: CGRect(x: -60, y: 40, width: 8000, height: 6000))
        display.accept(NSImage(size: NSSize(width: 900, height: 700)), filename: "persistent.dng", pixels: CGSize(width: 900, height: 700), native: true,
                       ticket: ticket, sourceRect: CGRect(x: 2000, y: 1800, width: 900, height: 700), fullExtent: display.fullExtent)
        XCTAssertFalse(InspectionFrameLayout.canReuseNativeFrame(isNative: display.native, isROI: true, zoomed: true))
        state.persistent.toggle()
        XCTAssertFalse(state.zoomed)
        InspectionFrameLayout.leaveNative(display: &display)
        let fit = InspectionFrameLayout.make(pixels: display.pixels, sourceRect: display.sourceRect, fullExtent: display.fullExtent,
                                             zoomed: state.zoomed, viewport: CGSize(width: 1000, height: 700), backing: 2)
        XCTAssertEqual(fit.imageSize.width, 933.333, accuracy: 0.01)
        XCTAssertEqual(fit.imageSize.height, 700, accuracy: 0.01)
        XCTAssertNil(display.sourceRect)
    }

    func testDisablingROIImmediatelyRestoresLastFullFitFrame() {
        var display = InspectionDisplay()
        let ticket = display.begin(filename: "toggle.dng")
        let full = NSImage(size: NSSize(width: 3200, height: 2400))
        let extent = CGRect(x: 300, y: -80, width: 3200, height: 2400)
        display.accept(full, filename: "toggle.dng", pixels: extent.size, native: false, ticket: ticket, fullExtent: extent)
        display.accept(NSImage(size: NSSize(width: 500, height: 400)), filename: "toggle.dng", pixels: CGSize(width: 500, height: 400), native: true,
                       ticket: ticket, sourceRect: CGRect(x: 1000, y: 600, width: 500, height: 400), fullExtent: extent)
        InspectionFrameLayout.disableROI(display: &display)
        XCTAssertTrue(display.image === full)
        XCTAssertEqual(display.fullExtent, extent)
        XCTAssertNil(display.sourceRect)
        XCTAssertEqual(display.filename, "toggle.dng")
    }

    func testPendingSelectionClearsOldROIFullExtentAndPlacementImmediately() {
        var display = InspectionDisplay()
        let ticket = display.begin(filename: "old.dng")
        let oldExtent = CGRect(x: -137, y: 59, width: 7200, height: 4800)
        let roiRect = CGRect(x: 4200, y: 2300, width: 1100, height: 800)
        display.accept(NSImage(size: NSSize(width: 1100, height: 800)), filename: "old.dng", pixels: roiRect.size,
                       native: true, ticket: ticket, sourceRect: roiRect, fullExtent: oldExtent)
        _ = display.beginSelection(filename: "new.dng") // loader/holder is pending and may have unrelated dimensions
        let layout = InspectionFrameLayout.make(pixels: display.pixels, sourceRect: display.sourceRect, fullExtent: display.fullExtent,
                                               zoomed: true, viewport: CGSize(width: 1000, height: 700), backing: 2)
        XCTAssertNil(display.image)
        XCTAssertTrue(display.filename.isEmpty)
        XCTAssertEqual(display.fullExtent, .zero)
        XCTAssertEqual(layout.clampSize, CGSize(width: 0.5, height: 0.5))
        XCTAssertEqual(layout.originOffset, .zero)
    }

    func testSelectionOwnershipClearsOldFrameAndRejectsOutOfOrderSameOwnerCompletions() {
        var display = InspectionDisplay()
        let aFirst = display.beginSelection(assetID: "stable-A", filename: "same-name.dng")
        display.accept(NSImage(size: NSSize(width: 400, height: 300)), assetID: "stable-A", filename: "same-name.dng", pixels: CGSize(width: 400, height: 300), native: false, ticket: aFirst)
        XCTAssertNotNil(display.image)

        let b = display.beginSelection(assetID: "stable-B", filename: "same-name.dng")
        XCTAssertNil(display.image, "selection ownership changes before async decode starts")
        XCTAssertFalse(display.owns(assetID: "stable-A"))
        XCTAssertTrue(display.owns(assetID: "stable-B"))
        display.accept(NSImage(size: NSSize(width: 900, height: 700)), assetID: "stable-A", filename: "same-name.dng", pixels: CGSize(width: 900, height: 700), native: true, ticket: aFirst)
        XCTAssertNil(display.image, "an old completion cannot publish under a duplicate filename")

        let aSecond = display.beginSelection(assetID: "stable-A", filename: "same-name.dng")
        display.accept(NSImage(size: NSSize(width: 800, height: 600)), assetID: "stable-B", filename: "same-name.dng", pixels: CGSize(width: 800, height: 600), native: true, ticket: b)
        XCTAssertNil(display.image, "A/B/A generations must reject the middle completion")
        display.accept(NSImage(size: NSSize(width: 500, height: 350)), assetID: "stable-A", filename: "same-name.dng", pixels: CGSize(width: 500, height: 350), native: false, ticket: aSecond)
        XCTAssertEqual(display.image?.size, NSSize(width: 500, height: 350))
    }

    func testForegroundSelectionTransitionClearsSynchronouslyForDuplicateFilenames() {
        let firstAsset = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/first/same.jpg"))
        let secondAsset = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/second/same.jpg"))
        XCTAssertNotEqual(firstAsset.id, secondAsset.id)
        var display = InspectionDisplay()
        let first = display.beginSelection(assetID: firstAsset.id, filename: firstAsset.filename)
        let image = NSImage(size: NSSize(width: 240, height: 160))
        display.accept(image, assetID: firstAsset.id, filename: firstAsset.filename, pixels: image.size, native: false, ticket: first)

        let ticket = InspectionLoadTransition.beginSelection(for: secondAsset, display: &display)
        XCTAssertTrue(display.owns(assetID: secondAsset.id))
        XCTAssertNil(display.image, "The production load transition clears before it can suspend for preload coordination")
        display.accept(image, assetID: firstAsset.id, filename: firstAsset.filename, pixels: image.size, native: false, ticket: first)
        XCTAssertNil(display.image)
        XCTAssertNotEqual(ticket, first)
    }

    func testFailedSelectionAndFitRestoreNeverRevealPreviousOwner() {
        var display = InspectionDisplay()
        let first = display.beginSelection(assetID: "first", filename: "duplicate.jpg")
        let fit = NSImage(size: NSSize(width: 640, height: 480))
        display.accept(fit, assetID: "first", filename: "duplicate.jpg", pixels: fit.size, native: false, ticket: first)
        display.accept(NSImage(size: NSSize(width: 400, height: 300)), assetID: "first", filename: "duplicate.jpg", pixels: CGSize(width: 400, height: 300), native: true, ticket: first, sourceRect: CGRect(x: 10, y: 20, width: 400, height: 300), fullExtent: CGRect(x: 0, y: 0, width: 2000, height: 1500))

        let second = display.beginSelection(assetID: "second", filename: "duplicate.jpg")
        XCTAssertNil(display.image)
        display.restoreFullFit()
        XCTAssertNil(display.image, "stale Fit fallback must be cleared at owner change")
        display.accept(nil, assetID: "second", filename: "duplicate.jpg", pixels: .zero, native: true, ticket: second)
        XCTAssertNil(display.image, "decode failure remains an honest empty/error state")
    }

    func testInspectionROIBoundsRetinaCenteredAndEdges() {
        let extent = CGRect(x: 100, y: 200, width: 4000, height: 3000)
        let centered = InspectionROI.sourceRect(extent: extent, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 1000, height: 700), backing: 2)
        XCTAssertEqual(centered.width, 2512, accuracy: 1)
        XCTAssertEqual(centered.height, 1912, accuracy: 1)
        XCTAssertTrue(extent.contains(centered))
        let edge = InspectionROI.sourceRect(extent: extent, center: CGPoint(x: 0, y: 0), viewport: CGSize(width: 1000, height: 700), backing: 1)
        XCTAssertTrue(extent.contains(edge))
        XCTAssertEqual(edge.minX, extent.minX, accuracy: 0.01)
        XCTAssertEqual(edge.maxY, extent.maxY, accuracy: 0.01)
        let portrait = CGRect(x: -17, y: 33, width: 1800, height: 4200)
        let corner = InspectionROI.sourceRect(extent: portrait, center: CGPoint(x: 1, y: 1), viewport: CGSize(width: 900, height: 600), backing: 2)
        XCTAssertTrue(portrait.contains(corner))
        XCTAssertEqual(corner.maxX, portrait.maxX, accuracy: 0.01)
        XCTAssertEqual(corner.minY, portrait.minY, accuracy: 0.01)
    }

    func testROIToggleDefaultsOnAndChangesOnlyInMemory() {
        var gate = InspectionROIToggle()
        XCTAssertTrue(gate.enabled)
        gate.toggle()
        XCTAssertFalse(gate.enabled)
        gate.toggle()
        XCTAssertTrue(gate.enabled)
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        XCTAssertNil(InspectionROI.requestRect(enabled: false, nativeSupported: true, extent: extent, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 1000, height: 700), backing: 2))
        XCTAssertNotNil(InspectionROI.requestRect(enabled: gate.enabled, nativeSupported: true, extent: extent, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 1000, height: 700), backing: 2))
        XCTAssertNil(InspectionROI.requestRect(enabled: true, nativeSupported: false, extent: extent, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 1000, height: 700), backing: 2))
    }

    @MainActor
    func testRepeatedDownAlwaysHoldsAndLongSecondPressDoesNotTogglePersistent() throws {
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var state = InspectionState()
        state.persistent = true
        surface.owner = InspectionSurface(down: { point, count in
            if count == 2 { state.end(); state.persistent.toggle() }
            else { state.begin(at: point, pixels: CGSize(width: 600, height: 400), viewport: surface.bounds.size) }
        }, drag: { _ in }, up: { state.end() }, navigate: { _ in }, backingChanged: { _ in })
        func event(_ type: NSEvent.EventType, _ count: Int, _ time: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: time, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        surface.mouseDown(with: try event(.leftMouseDown, 1, 1))
        surface.mouseUp(with: try event(.leftMouseUp, 1, 1.01))
        surface.mouseDown(with: try event(.leftMouseDown, 2, 1.1))
        XCTAssertTrue(state.held, "Second press must enter hold before click/hold intent is known")
        XCTAssertTrue(state.zoomed)
        XCTAssertTrue(surface.hasCaptureMonitor)
        surface.mouseUp(with: try event(.leftMouseUp, 2, 2.1 + NSEvent.doubleClickInterval))
        XCTAssertTrue(state.persistent, "Deliberate second hold is not a double-click toggle")
        XCTAssertFalse(state.held)
    }

    @MainActor
    func testShortDoubleClickTogglesOnceButDragWheelAndCancelDoNot() throws {
        for action in ["click", "drag", "wheel", "cancel", "longFirst"] {
            let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            var state = InspectionState()
            var toggles = 0
            surface.owner = InspectionSurface(down: { point, count in
                if count == 2 { state.end(); state.persistent.toggle(); toggles += 1 }
                else { state.begin(at: point, pixels: CGSize(width: 600, height: 400), viewport: surface.bounds.size) }
            }, drag: { _ in }, up: { state.end() }, navigate: { _ in }, backingChanged: { _ in })
            func event(_ type: NSEvent.EventType, _ count: Int, _ time: Double, _ x: CGFloat = 50) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 50), modifierFlags: [], timestamp: time, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            }
            XCTAssertTrue(surface.acceptsFirstMouse(for: nil))
            XCTAssertFalse(surface.acceptsFirstResponder, "Do not steal keyboard ownership")
            surface.mouseDown(with: try event(.leftMouseDown, 1, 1))
            surface.mouseUp(with: try event(.leftMouseUp, 1, action == "longFirst" ? 1 + NSEvent.doubleClickInterval + 0.1 : 1.01))
            surface.mouseDown(with: try event(.leftMouseDown, 2, 2))
            XCTAssertTrue(state.held, action)
            XCTAssertTrue(surface.hasCaptureMonitor, action)
            if action == "drag" { surface.mouseDragged(with: try event(.leftMouseDragged, 2, 2.01, 60)) }
            if action == "wheel" {
                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
                _ = surface.routeCapturedEvent(try XCTUnwrap(NSEvent(cgEvent: cg)), leftPressed: true)
            }
            if action == "cancel" { surface.cancelOperation(nil) }
            let up = try event(.leftMouseUp, 2, 2.02)
            _ = surface.routeCapturedEvent(up, leftPressed: false)
            surface.mouseUp(with: up)
            XCTAssertEqual(toggles, action == "click" ? 1 : 0, action)
            XCTAssertEqual(state.persistent, action == "click", action)
            XCTAssertFalse(state.held, action)
            XCTAssertFalse(surface.hasCaptureMonitor, action)
            if action == "click" {
                // A second complete double click must toggle back to Fit.
                surface.mouseDown(with: try event(.leftMouseDown, 1, 3))
                surface.mouseUp(with: try event(.leftMouseUp, 1, 3.01))
                surface.mouseDown(with: try event(.leftMouseDown, 2, 3.1))
                surface.mouseUp(with: try event(.leftMouseUp, 2, 3.11))
                XCTAssertFalse(state.zoomed)
                XCTAssertEqual(toggles, 2)
            }
        }
    }

    @MainActor
    func testHeldOutsideWheelReleaseIdleAndDuplicateDelivery() throws {
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var state = InspectionState()
        var steps = 0
        var releases = 0
        surface.owner = InspectionSurface(down: { point, _ in
            state.begin(at: point, pixels: CGSize(width: 600, height: 400), viewport: surface.bounds.size)
        }, drag: { _ in }, up: { state.end(); releases += 1 }, navigate: { steps += $0 }, backingChanged: { _ in })
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: 200, y: 200)
        let scroll = try XCTUnwrap(NSEvent(cgEvent: cg))
        let down = try mouse(.leftMouseDown, CGPoint(x: 50, y: 50))
        surface.mouseDown(with: down)
        surface.scrollWheel(with: scroll)
        XCTAssertEqual(steps, 1, "Held gesture owns outside wheel")
        surface.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 200, y: 200)))
        XCTAssertFalse(state.zoomed)
        XCTAssertNil(surface.lastPoint)
        XCTAssertEqual(releases, 1)
    }

    @MainActor
    func testCaptureMonitorRoutingAndLifecycle() throws {
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var state = InspectionState()
        var steps = 0
        var releases = 0
        surface.owner = InspectionSurface(down: { point, _ in
            state.begin(at: point, pixels: CGSize(width: 600, height: 400), viewport: surface.bounds.size)
        }, drag: { _ in }, up: { state.end(); releases += 1 }, navigate: { steps += $0 }, backingChanged: { _ in })
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func scroll(_ timestamp: UInt64) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0))
            cg.location = CGPoint(x: 200, y: 200)
            cg.timestamp = timestamp
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let first = try scroll(1_000_000_000)
        XCTAssertTrue(surface.routeCapturedEvent(first, leftPressed: false) === first)
        XCTAssertFalse(surface.hasCaptureMonitor)
        surface.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertTrue(surface.hasCaptureMonitor)
        let center = state.center
        XCTAssertNil(surface.routeCapturedEvent(first, leftPressed: true))
        surface.scrollWheel(with: first) // accidental duplicate must not accumulate precise delta twice
        XCTAssertEqual(steps, 0)
        XCTAssertNil(surface.routeCapturedEvent(try scroll(1_100_000_000), leftPressed: true))
        XCTAssertEqual(steps, 1)
        XCTAssertEqual(state.center, center)
        let up = try mouse(.leftMouseUp)
        XCTAssertTrue(surface.routeCapturedEvent(up, leftPressed: false) === up)
        surface.mouseUp(with: up)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(state.zoomed)
        XCTAssertFalse(surface.hasCaptureMonitor)
        XCTAssertNil(surface.lastPoint)
        XCTAssertTrue(surface.routeCapturedEvent(first, leftPressed: false) === first)
        state.persistent = true
        surface.mouseDown(with: try mouse(.leftMouseDown))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertFalse(surface.hasCaptureMonitor)
        XCTAssertFalse(state.held)
        XCTAssertTrue(state.zoomed)
        surface.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertTrue(surface.routeCapturedEvent(first, leftPressed: false) === first)
        XCTAssertFalse(surface.hasCaptureMonitor, "Recover a missed mouseUp without stealing sidebar scroll")
        surface.mouseDown(with: try mouse(.leftMouseDown))
        surface.cancelOperation(nil)
        XCTAssertFalse(surface.hasCaptureMonitor)
        surface.mouseDown(with: try mouse(.leftMouseDown))
        InspectionSurface.dismantleNSView(surface, coordinator: ())
        XCTAssertFalse(surface.hasCaptureMonitor)
    }

    @MainActor
    func testCaptureWindowCloseDetachAndFocusLoss() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(surface)
        var held = false
        surface.owner = InspectionSurface(down: { _, _ in held = true }, drag: { _ in }, up: { held = false }, navigate: { _ in XCTFail("Other window must not navigate") }, backingChanged: { _ in })
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            surface.mouseDown(with: down)
            XCTAssertTrue(surface.hasCaptureMonitor)
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertFalse(surface.hasCaptureMonitor)
            XCTAssertFalse(held)
        }
        surface.mouseDown(with: down)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        let foreign = try XCTUnwrap(NSEvent(cgEvent: cg)) // no owning window
        XCTAssertTrue(surface.routeCapturedEvent(foreign, leftPressed: true) === foreign)
        surface.removeFromSuperview()
        XCTAssertFalse(surface.hasCaptureMonitor)
        XCTAssertFalse(held)
    }

    func testStagedDisplayRetainsFrameAcrossLoadFailureAndRejectsStaleResult() {
        var display = InspectionDisplay()
        let first = display.begin(filename: "A.jpg")
        let image = NSImage(size: CGSize(width: 6000, height: 4000))
        display.accept(image, filename: "A.jpg", pixels: image.size, native: false, ticket: first)
        let next = display.begin(filename: "B.jpg")
        XCTAssertTrue(display.image === image)
        XCTAssertEqual(display.filename, "A.jpg")
        XCTAssertFalse(display.native)
        display.accept(nil, filename: "B.jpg", pixels: .zero, native: true, ticket: next)
        XCTAssertTrue(display.image === image)
        display.accept(NSImage(size: .init(width: 20, height: 20)), filename: "A.jpg", pixels: .zero, native: true, ticket: first)
        XCTAssertTrue(display.image === image)
        display.accept(image, filename: "B.jpg", pixels: image.size, native: true, ticket: next)
        XCTAssertEqual(display.filename, "B.jpg")
        XCTAssertTrue(display.native)
        _ = display.begin(filename: "B.jpg") // zoom/reload keeps valid native pixels
        XCTAssertTrue(display.image === image)
        XCTAssertTrue(display.native)
    }

    func testDecodeKeyIgnoresPostDecodeExposureButTracksWhiteBalance() {
        var a = XMPMetadata()
        var b = XMPMetadata()
        b.exposure2012 = 2
        XCTAssertEqual(RAWDecodeSettings(a), RAWDecodeSettings(b))
        b.temperature = 5000
        XCTAssertNotEqual(RAWDecodeSettings(a), RAWDecodeSettings(b))
        a.temperature = 5000
        XCTAssertEqual(RAWDecodeSettings(a), RAWDecodeSettings(b))
        b.tint = 10
        XCTAssertNotEqual(RAWDecodeSettings(a), RAWDecodeSettings(b))
    }

    func testSynthetic24MPDecodeRenderSwitchTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CIContext()
        let source = CIImage(color: CIColor(red: 0.25, green: 0.4, blue: 0.6)).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: CIFilter(name: "CIRandomGenerator")!.outputImage!]).cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        for name in ["a.jpg", "b.jpg"] {
            try context.writeJPEGRepresentation(of: source, to: root.appendingPathComponent(name), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        RAWImageLoader.shared.clearCache()
        for name in ["a.jpg", "a.jpg", "b.jpg", "a.jpg"] {
            let start = CFAbsoluteTimeGetCurrent()
            let loaded = await RAWImageLoader.shared.loadBaseHolder(from: root.appendingPathComponent(name))
            let holder = try XCTUnwrap(loaded)
            let decoded = CFAbsoluteTimeGetCurrent()
            let image = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: nil, fullResolution: true))
            XCTAssertEqual(image.size, CGSize(width: 6000, height: 4000))
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 24000, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: 6000, height: 4000))
            print("SYNTHETIC24MP \(name) decode_ms=\((decoded-start)*1000) native_render_ms=\((CFAbsoluteTimeGetCurrent()-decoded)*1000)")
        }
    }

    func testPersistentPanClampWheelAndStaleGuard() {
        var state = InspectionState()
        state.persistent = true
        state.begin(at: .zero, pixels: CGSize(width: 6000, height: 4000), viewport: CGSize(width: 1200, height: 800))
        state.pan(delta: CGSize(width: 100, height: -100), displayed: CGSize(width: 3000, height: 2000), viewport: CGSize(width: 1200, height: 800))
        XCTAssertEqual(state.center.x, 0.5 - 100.0 / 3000, accuracy: 0.0001)
        state.end()
        XCTAssertTrue(state.zoomed)
        var wheel = InspectionWheelGate()
        XCTAssertEqual(wheel.step(delta: -1, precise: false, momentum: false, inside: false, time: 1), 0)
        XCTAssertEqual(wheel.step(delta: -1, precise: false, momentum: false, inside: true, time: 1), 1)
        XCTAssertEqual(wheel.step(delta: -1, precise: false, momentum: false, inside: true, time: 1.05), 0)
        XCTAssertEqual(wheel.step(delta: 100, precise: true, momentum: true, inside: true, time: 2), 0)
        var revision = InspectionRevision()
        let old = revision.next()
        let new = revision.next()
        XCTAssertFalse(revision.accepts(old))
        XCTAssertTrue(revision.accepts(new))
    }

    @MainActor
    func testNativeMouseSurfaceDeliversDownDragUpWithoutClickGesture() throws {
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        var state = InspectionState()
        var clickCount = 0
        surface.owner = InspectionSurface(down: { point, count in
            clickCount = count
            state.begin(at: point, pixels: CGSize(width: 6000, height: 4000), viewport: surface.bounds.size)
        }, drag: { delta in
            state.pan(delta: delta, displayed: CGSize(width: 3000, height: 2000), viewport: surface.bounds.size)
        }, up: { state.end() }, navigate: { _ in }, backingChanged: { _ in })
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 600, y: 400)))
        XCTAssertTrue(state.held)
        XCTAssertTrue(state.zoomed)
        XCTAssertEqual(clickCount, 1)
        let previous = state.center
        surface.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 650, y: 400)))
        XCTAssertNotEqual(state.center.x, previous.x)
        surface.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 650, y: 400)))
        XCTAssertFalse(state.zoomed)
    }

    @MainActor
    func testHeldWheelOwnerRefreshStillDeliversRelease() throws {
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        var state = InspectionState()
        var selected = 0
        func owner() -> InspectionSurface {
            InspectionSurface(down: { point, _ in
                state.begin(at: point, pixels: CGSize(width: 6000, height: 4000), viewport: surface.bounds.size)
            }, drag: { _ in }, up: { state.end() }, navigate: { selected += $0 }, backingChanged: { _ in })
        }
        surface.owner = owner()
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 600, y: 400), modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        surface.mouseDown(with: down)
        let center = state.center
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: 600, y: 400)
        surface.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(selected, 1)
        surface.owner = owner() // SwiftUI updates callbacks for the new selection.
        XCTAssertTrue(state.held)
        XCTAssertEqual(state.center, center)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 600, y: 400), modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        surface.mouseUp(with: up)
        XCTAssertFalse(state.zoomed)
        state.persistent = true
        surface.mouseDown(with: down)
        surface.owner = owner()
        surface.mouseUp(with: up)
        XCTAssertTrue(state.zoomed)
        XCTAssertFalse(state.held)
    }

    func testSourceCenterRemainsNormalizedAcrossDifferentDimensions() {
        var state = InspectionState()
        state.persistent = true
        state.center = CGPoint(x: 0.7, y: 0.6)
        let viewport = CGSize(width: 1200, height: 800)
        state.clamp(displayed: CGSize(width: 3000, height: 2000), viewport: viewport)
        XCTAssertEqual(state.center.x * 6000, 4200, accuracy: 0.001)
        state.clamp(displayed: CGSize(width: 2000, height: 3000), viewport: viewport)
        XCTAssertEqual(state.center.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(state.center.y, 0.6, accuracy: 0.001)
        state.center = CGPoint(x: -10, y: 10)
        state.clamp(displayed: CGSize(width: 3000, height: 2000), viewport: viewport)
        XCTAssertEqual(state.center.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(state.center.y, 0.8, accuracy: 0.001)
    }

    func testPreciseWheelThresholdAndCooldown() {
        var gate = InspectionWheelGate()
        XCTAssertEqual(gate.step(delta: -8, precise: true, momentum: false, inside: true, time: 1), 0)
        XCTAssertEqual(gate.step(delta: -8, precise: true, momentum: false, inside: true, time: 1.01), 0)
        XCTAssertEqual(gate.step(delta: -8, precise: true, momentum: false, inside: true, time: 1.02), 1)
        XCTAssertEqual(gate.step(delta: -100, precise: true, momentum: false, inside: true, time: 1.03), 0)
        XCTAssertEqual(gate.step(delta: 20, precise: true, momentum: false, inside: true, time: 1.3), -1)
    }

    @MainActor
    func testPreviewOnlyHolderRejectsNativeAndCompletesFailure() async {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        var holder = BaseImageHolder(full: image, display: image, interactive: image, fullExtent: image.extent, displayExtent: image.extent, interactiveExtent: image.extent, baseTemperature: nil, baseTint: nil, baseExposure: nil, isRaw: true)
        holder.supportsNativeInspection = false
        XCTAssertNil(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: nil, fullResolution: true))
        let completed = expectation(description: "Failed native render completes instead of waiting forever")
        LiveDevelopPreviewEngine.shared.requestRender(baseHolder: holder, cameraModel: nil, xmp: nil, fullResolution: true) { result in
            XCTAssertNil(result)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
    }

    func testFullResolutionRenderDoesNotUseProxy() throws {
        let full = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 20))
        let proxy = full.transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1))
        let holder = BaseImageHolder(full: full, display: proxy, interactive: proxy, fullExtent: full.extent, displayExtent: proxy.extent, interactiveExtent: proxy.extent, baseTemperature: nil, baseTint: nil, baseExposure: nil, isRaw: false)
        let image = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: nil, fullResolution: true))
        XCTAssertEqual(image.size.width, 3000)
        XCTAssertEqual(image.size.height, 20)
        let roi = CGRect(x: 120, y: 5, width: 120, height: 12)
        let regional = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: nil, fullResolution: true, sourceRect: roi))
        XCTAssertEqual(regional.size.width, roi.width)
        XCTAssertEqual(regional.size.height, roi.height)
        XCTAssertNil(RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil, xmp: nil, fullResolution: true, sourceRect: CGRect(x: 5000, y: 5, width: 120, height: 12)))
    }

    func testInspectionDisplayRejectsStaleROIAndRetainsRectProvenance() {
        var display = InspectionDisplay()
        let oldTicket = display.begin(filename: "one.dng")
        let current = display.begin(filename: "two.dng")
        let image = NSImage(size: NSSize(width: 100, height: 80))
        let roi = CGRect(x: 300, y: 400, width: 100, height: 80)
        display.accept(image, filename: "one.dng", pixels: image.size, native: true, ticket: oldTicket, sourceRect: roi)
        XCTAssertNil(display.image)
        display.accept(image, filename: "two.dng", pixels: image.size, native: true, ticket: current, sourceRect: roi)
        XCTAssertEqual(display.filename, "two.dng")
        XCTAssertEqual(display.sourceRect, roi)
    }

    func testHoldAcrossSelectionReturnsFitAndRetinaCoordinates() {
        var state = InspectionState()
        state.begin(at: CGPoint(x: 750, y: 400), pixels: CGSize(width: 6000, height: 4000), viewport: CGSize(width: 1200, height: 800))
        XCTAssertTrue(state.zoomed)
        XCTAssertEqual(state.center.x, 0.625, accuracy: 0.0001)
        XCTAssertEqual(state.displaySize(pixels: CGSize(width: 6000, height: 4000), viewport: CGSize(width: 1200, height: 800), backing: 2).width, 3000)
        // Selection never owns or resets the inspection state.
        _ = state.displaySize(pixels: CGSize(width: 4000, height: 6000), viewport: CGSize(width: 1200, height: 800), backing: 2)
        state.end()
        XCTAssertFalse(state.zoomed)
    }

    func testROIThrottleSubmitsLatestContinuousPanAtBoundedIntervals() {
        var throttle = InspectionROIThrottle()
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0), 0.025, accuracy: 0.000_001)
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0.008), 0.025, accuracy: 0.000_001)
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0.016), 0.025, accuracy: 0.000_001)
        // The production task submits the most recent ticket when this deadline arrives.
        throttle.submitted(at: 0.025)
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0.032), 0.057, accuracy: 0.000_001)
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0.048), 0.057, accuracy: 0.000_001)
        throttle.submitted(at: 0.057)
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0.090), 0.115, accuracy: 0.000_001)
        throttle.cancelPending()
        XCTAssertEqual(throttle.dueTime(forRequestAt: 0.200), 0.225, accuracy: 0.000_001)
    }

    func testFirstDragDoesNotRestorePreDownLayoutSnapshotOverHeldState() {
        var state = InspectionState()
        let layoutSnapshot = state
        XCTAssertFalse(layoutSnapshot.held, "The captured pre-down layout value represents the stale callback case")
        state.begin(at: CGPoint(x: 700, y: 400), pixels: CGSize(width: 6000, height: 4000), viewport: CGSize(width: 1200, height: 800))
        XCTAssertTrue(state.held)
        state.applyDrag(delta: CGSize(width: 8, height: 0),
                        displayed: CGSize(width: 3000, height: 2000), viewport: CGSize(width: 1200, height: 800))
        XCTAssertTrue(state.held, "The first drag must not restore held=false from the captured pre-down layout value")
        XCTAssertNotEqual(state.center, CGPoint(x: 0.5, y: 0.5), "The drag must preserve the center established by mouseDown")
    }
}
