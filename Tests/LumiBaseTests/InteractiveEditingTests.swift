import XCTest
import CoreImage
@testable import LumiBase

final class InteractiveEditingTests: XCTestCase {
    func testClearDuringPreparationAndStaleRequestCannotPublish() async throws {
        guard let source = HighlightsSourceRecipe(url: HighlightsIntegrationTests.source) else { throw XCTSkip("RAW fixture required") }
        try await Task.detached {
            let service = NativeHighlightsService()
            let xmp = XMPMetadata(temperature: 3650, tint: 8, highlights2012: -80)
            XCTAssertNil(service.image(source: source, xmp: xmp, cameraModel: nil, isCurrent: { false }))
            XCTAssertEqual(service.statistics.endpointDecodes, 0)
            var checks = 0
            let cancelled = service.image(source: source, xmp: xmp, cameraModel: nil, isCurrent: {
                checks += 1
                if checks == 3 { service.clear() }
                return true
            })
            XCTAssertNil(cancelled)
            XCTAssertEqual(service.statistics.entries, 0)
            XCTAssertEqual(service.statistics.preparations, 0)
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.preparations, 1)
            XCTAssertEqual(service.statistics.endpointDecodes, 4, "clear must evict endpoint graphs too")
        }.value
    }

    func testPostDecodeEditsReuseRAWEndpointsButWBInvalidates() async throws {
        guard let source = HighlightsSourceRecipe(url: HighlightsIntegrationTests.source) else { throw XCTSkip("RAW fixture required") }
        try await Task.detached {
            let service = NativeHighlightsService()
            var xmp = XMPMetadata(temperature: 3650, tint: 8, highlights2012: -80)
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.endpointDecodes, 2)
            xmp.exposure2012 = 0.3
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.endpointDecodes, 2)
            XCTAssertEqual(service.statistics.preparations, 2, "EV changes the exact global field")
            xmp.tint = 18
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.endpointDecodes, 4)
            service.clear()
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.endpointDecodes, 6)
        }.value
    }

    func testHighlightsStrengthReusesExactPreparedAnchor() async throws {
        guard let source = HighlightsSourceRecipe(url: HighlightsIntegrationTests.source) else { throw XCTSkip("RAW fixture required") }
        try await Task.detached {
            let service = NativeHighlightsService()
            var xmp = XMPMetadata(temperature: 3650, tint: 8, highlights2012: -80)
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            xmp.highlights2012 = -40
            let cached = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.preparations, 1, "Strength is not an anchor preparation dependency")
            let fresh = NativeHighlightsService()
            let reference = try XCTUnwrap(fresh.image(source: source, xmp: xmp, cameraModel: nil))
            func pixels(_ image: CIImage) -> [Float] {
                var data = [Float](repeating: 0, count: 64 * 64 * 4)
                service.renderContext.render(image, toBitmap: &data, rowBytes: 64 * 16,
                    bounds: CGRect(x: 4400, y: 2400, width: 64, height: 64), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
                return data
            }
            XCTAssertEqual(pixels(cached), pixels(reference))
            service.clear()
            _ = try XCTUnwrap(service.image(source: source, xmp: xmp, cameraModel: nil))
            XCTAssertEqual(service.statistics.preparations, 2)
        }.value
    }
}
