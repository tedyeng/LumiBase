import XCTest
import AppKit
@testable import LumiBase

final class ImageLoadingConcurrencyTests: XCTestCase {
    /// Real production API regression; launch with an isolated CFFIXED_USER_HOME and
    /// an external process deadline so a starved cooperative pool cannot hide failure.
    func testConcurrentRAWThumbnailsLeavePreviewResponsive() throws {
        guard let folder = ProcessInfo.processInfo.environment["LUMIBASE_LOADING_STRESS_FOLDER"] else {
            throw XCTSkip("Set LUMIBASE_LOADING_STRESS_FOLDER for read-only real RAW stress")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "cr3" }.sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(urls.count, 16)
        guard urls.count >= 16 else { return }
        let count = 48
        let thumbnails = expectation(description: "All cold RAW thumbnails finish")
        thumbnails.expectedFulfillmentCount = count
        let preview = expectation(description: "Foreground RAW preview finishes despite thumbnail fan-out")
        let stamp = Date()
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<count {
            let asset = PhotoAsset(fileURL: urls[index % 16], dateModified: stamp)
            Task.detached(priority: .userInitiated) {
                let result = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 180 + index)
                XCTAssertNotNil(result, "thumbnail \(index)")
                thumbnails.fulfill()
            }
        }
        // Enqueue from GCD, not Task.sleep: the triggering timer itself must not
        // depend on the cooperative executor whose forward progress is under test.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            Task.detached(priority: .userInitiated) {
                let loader = RAWImageLoader()
                let holder = await loader.loadBaseHolder(from: urls[0], useSharedCache: false)
                XCTAssertNotNil(holder)
                if let holder {
                    let image = loader.renderProcessed(baseHolder: holder, cameraModel: "Canon EOS R5", xmp: .empty, interactive: true)
                    XCTAssertNotNil(image)
                }
                print("LOADING_STRESS foreground_preview_ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
                preview.fulfill()
            }
        }
        wait(for: [thumbnails, preview], timeout: 45)
        print("LOADING_STRESS requested_thumbnails=\(count) raw_sources=16 total_ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
    }
}
