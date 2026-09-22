import XCTest
import AppKit
import CoreImage
@testable import LumiBase

final class InspectionTests: XCTestCase {
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
}
