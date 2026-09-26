import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class InteractiveQueueTests: XCTestCase {
    @MainActor func testCancellationRejectsRunningCallbackAndAllowsNextRequest() async throws {
        let entered = expectation(description: "running")
        let obsolete = expectation(description: "cancelled callback"); obsolete.isInverted = true
        let newest = expectation(description: "new source")
        let gate = DispatchSemaphore(value: 0)
        let engine = LiveDevelopPreviewEngine(renderer: { request in
            if request.cameraModel == "old-source" { entered.fulfill(); _ = gate.wait(timeout: .now() + 3) }
            return nil
        })
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let holder = BaseImageHolder(full: ci, display: ci, interactive: ci, fullExtent: ci.extent, displayExtent: ci.extent, interactiveExtent: ci.extent, baseTemperature: nil, baseTint: nil, baseExposure: nil, isRaw: false)
        engine.requestRender(baseHolder: holder, cameraModel: "old-source", xmp: nil) { _ in obsolete.fulfill() }
        await fulfillment(of: [entered], timeout: 2)
        engine.cancelPending()
        gate.signal()
        engine.requestRender(baseHolder: holder, cameraModel: "new-source", xmp: nil) { image in XCTAssertNil(image); newest.fulfill() }
        await fulfillment(of: [newest, obsolete], timeout: 1)
        XCTAssertEqual(engine.statistics.published, 1)
    }

    @MainActor func testLatestWinsRejectsRunningAndReplacedCallbacks() async throws {
        let entered = expectation(description: "first running")
        let latest = expectation(description: "latest publishes")
        let stale = expectation(description: "obsolete must not publish"); stale.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        let engine = LiveDevelopPreviewEngine(renderer: { request in
            if request.xmp?.exposure2012 == 1 { entered.fulfill(); _ = gate.wait(timeout: .now() + 5) }
            return NSImage(size: CGSize(width: 10, height: 10))
        })
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let holder = BaseImageHolder(full: ci, display: ci, interactive: ci, fullExtent: ci.extent, displayExtent: ci.extent, interactiveExtent: ci.extent, baseTemperature: nil, baseTint: nil, baseExposure: nil, isRaw: false)
        engine.requestRender(baseHolder: holder, cameraModel: nil, xmp: XMPMetadata(exposure2012: 1)) { _ in stale.fulfill() }
        await fulfillment(of: [entered], timeout: 3)
        engine.requestRender(baseHolder: holder, cameraModel: nil, xmp: XMPMetadata(exposure2012: 2)) { _ in stale.fulfill() }
        engine.requestRender(baseHolder: holder, cameraModel: nil, xmp: XMPMetadata(exposure2012: 3)) { image in XCTAssertNotNil(image); latest.fulfill() }
        gate.signal()
        await fulfillment(of: [latest, stale], timeout: 1)
    }
}
