import XCTest
import AppKit
import SwiftUI
@testable import LumiBase

final class EditingInputTests: XCTestCase {
    @MainActor func testNativeTrackDoubleClickResetsWithoutDraggingAgain() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        let track = SliderTrackView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = track
        var changes: [Double] = []; var resets = 0; var ends = 0
        track.changed = { changes.append($0) }; track.reset = { resets += 1 }; track.ended = { ends += 1 }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ count: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
        }
        track.mouseDown(with: try mouse(.leftMouseDown, 80, 1))
        track.mouseDragged(with: try mouse(.leftMouseDragged, 160, 1))
        track.mouseUp(with: try mouse(.leftMouseUp, 160, 1))
        XCTAssertEqual(changes, [0.4, 0.8]); XCTAssertEqual(ends, 1)
        track.mouseDown(with: try mouse(.leftMouseDown, 160, 2))
        track.mouseDragged(with: try mouse(.leftMouseDragged, 190, 2))
        track.mouseUp(with: try mouse(.leftMouseUp, 190, 2))
        XCTAssertEqual(resets, 1); XCTAssertEqual(ends, 1); XCTAssertEqual(changes, [0.4, 0.8])
    }

    @MainActor func testActualSwiftUIFilmstripBridgeLivesInsideItsScrollView() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        let host = NSHostingView(rootView: FilmstripView(appState: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 85), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let bridge = try XCTUnwrap(descendants(host).compactMap { $0 as? FilmstripWheelView }.first)
        XCTAssertNotNil(bridge.enclosingScrollView, "Production SwiftUI hierarchy must provide the scoped scroll target")
        XCTAssertNil(bridge.hitTest(.zero), "Thumbnail selection must pass through the bridge")
    }

    @MainActor func testFilmstripWheelBoundsAndHeldGestureOwnership() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = try XCTUnwrap(window.contentView)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 85))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 2400, height: 85))
        let bridge = FilmstripWheelView(frame: document.bounds)
        document.addSubview(bridge); scroll.documentView = document; root.addSubview(scroll)
        func wheel(_ y: CGFloat) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            // NSEvent's location/window are assigned via a concrete test subclass below.
            return TestWheel(original: event, point: NSPoint(x: 200, y: y), owningWindow: window)
        }
        let inside = try wheel(40)
        XCTAssertNil(bridge.route(inside, pressedButtons: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 0)
        let before = scroll.contentView.bounds.origin
        let surface = InspectionSurface.Surface(frame: NSRect(x: 0, y: 85, width: 600, height: 415))
        root.addSubview(surface)
        var inspection = InspectionState(); inspection.persistent = true
        var navigation = 0
        surface.owner = InspectionSurface(down: { point, _ in inspection.begin(at: point, pixels: CGSize(width: 6000, height: 4000), viewport: surface.bounds.size) }, drag: { _ in }, up: { inspection.end() }, navigate: { navigation += $0 }, backingChanged: { _ in })
        surface.scrollWheel(with: inside)
        XCTAssertEqual(navigation, 0, "Persistent 100% must not steal wheel over the filmstrip")
        XCTAssertNotNil(bridge.route(try wheel(200), pressedButtons: 0), "100% image viewport retains its own wheel")
        XCTAssertNotNil(bridge.route(inside, pressedButtons: 1), "Held image capture owns wheel even across filmstrip")
        XCTAssertEqual(scroll.contentView.bounds.origin, before)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 200), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        surface.mouseDown(with: down)
        let heldWheel = try wheel(40)
        XCTAssertNotNil(bridge.route(heldWheel, pressedButtons: 1))
        XCTAssertNil(surface.routeCapturedEvent(heldWheel, leftPressed: true))
        XCTAssertEqual(navigation, 1)
        surface.endCapture()
        XCTAssertTrue(inspection.persistent)
        bridge.removeFromSuperview()
        XCTAssertNotNil(bridge.route(inside, pressedButtons: 0))
    }

    func testEverySliderResetUsesMetadataDefaultAndPreservesOtherFields() {
        for field in BasicSliderField.allCases {
            var xmp = XMPMetadata(exposure2012: 1, temperature: 4150, tint: 18, contrast2012: 10, highlights2012: -80, shadows2012: 10, whites2012: 10, blacks2012: -10, dehaze: 10, vibrance: 10, saturation: 10, clarity2012: 10, texture: 10)
            xmp.title = "unchanged"
            field.reset(in: &xmp)
            XCTAssertTrue(field.isDefault(in: xmp))
            XCTAssertEqual(xmp.title, "unchanged")
            if field == .temp { XCTAssertNil(xmp.temperature); XCTAssertEqual(xmp.tint, 18) }
            if field == .tint { XCTAssertNil(xmp.tint); XCTAssertEqual(xmp.temperature, 4150) }
            if field != .exposure { XCTAssertEqual(xmp.exposure2012, 1) }
        }
    }
}

private final class TestWheel: NSEvent {
    let original: NSEvent
    let point: NSPoint
    let owningWindow: NSWindow
    init(original: NSEvent, point: NSPoint, owningWindow: NSWindow) { self.original = original; self.point = point; self.owningWindow = owningWindow; super.init() }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var window: NSWindow? { owningWindow }
    override var scrollingDeltaY: CGFloat { -3 }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var momentumPhase: NSEvent.Phase { [] }
    override var timestamp: TimeInterval { 1 }
}
