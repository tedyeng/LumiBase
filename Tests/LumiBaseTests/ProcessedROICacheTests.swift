import XCTest
import AppKit
@testable import LumiBase

final class ProcessedROICacheTests: XCTestCase {
    func testProcessedROIAdmissionEnforcesBitmapBudgetAndEntryLimit() {
        var cache = ProcessedROIBitmapCache(capacityBytes: 100, maximumEntries: 3)
        let entries = (0..<4).map { index -> ProcessedROIEntry in
            let identity = ProcessedROIIdentity(assetID: "a\(index)", fileVersion: "v1", developSettings: "settings",
                cameraModel: "camera", fullExtent: CGRect(x: 0, y: 0, width: 100, height: 80),
                sourceRect: CGRect(x: index, y: 0, width: 10, height: 10), normalizedCenter: CGPoint(x: 0.5, y: 0.5),
                viewport: CGSize(width: 10, height: 10), backingScale: 1, orientation: 1)
            return ProcessedROIEntry(image: NSImage(size: CGSize(width: 10, height: 10)), identity: identity, costBytes: 40)
        }
        for entry in entries { cache.insert(entry) }
        XCTAssertLessThanOrEqual(cache.accountedBytes, 100, "processed ROI cache must enforce its strict bitmap budget")
        XCTAssertLessThanOrEqual(cache.count, 3, "processed ROI cache must retain at most three completed regions")
    }

    func testIsolatedSchedulerRunsAtMostOneAndForegroundInvalidatesPendingPublication() {
        var scheduler = ProcessedROIScheduler()
        let a = identity("a"), b = identity("b")
        scheduler.prioritize([a, b])
        let active = try! XCTUnwrap(scheduler.beginNext())
        XCTAssertEqual(scheduler.runningCount, 1)
        scheduler.prioritize([b, a])
        XCTAssertEqual(scheduler.runningCount, 1, "reversal cannot start a second speculative decode while active work unwinds")
        XCTAssertFalse(scheduler.finish(active), "reversed active work cannot publish under its old generation")
        XCTAssertEqual(scheduler.beginNext()?.identity, b, "reversal reprioritizes the still-pending neighbor")
        scheduler.prioritize([a])
        XCTAssertTrue(scheduler.isPending(a), "repeating a target while another job unwinds keeps its current request registered")
        scheduler.foregroundStarted()
        XCTAssertNil(scheduler.beginNext(), "foreground work owns priority")
    }

    func testSyntheticProcessedROIIsRenderedAndCacheHitReusesExactBitmap() throws {
        let base = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let holder = BaseImageHolder(full: base, display: base, interactive: base, fullExtent: base.extent,
            displayExtent: base.extent, interactiveExtent: base.extent, baseTemperature: nil, baseTint: nil,
            baseExposure: nil, isRaw: false)
        let roi = CGRect(x: 8, y: 6, width: 24, height: 20)
        let image = try XCTUnwrap(RAWImageLoader().renderProcessed(baseHolder: holder, cameraModel: nil, xmp: .empty, fullResolution: true, sourceRect: roi))
        let key = ProcessedROIIdentity(assetID: "synthetic", fileVersion: "v1", developSettings: "complete", cameraModel: "",
            fullExtent: base.extent, sourceRect: roi, normalizedCenter: CGPoint(x: 0.5, y: 0.5),
            viewport: roi.size, backingScale: 2, orientation: 1)
        var cache = ProcessedROIBitmapCache(capacityBytes: 1_000_000, maximumEntries: 3)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let entry = ProcessedROIEntry(image: image, identity: key, costBytes: cg.bytesPerRow * cg.height)
        cache.insert(entry)
        XCTAssertTrue(cache.value(for: key)?.image === image, "the warm foreground lookup must return the actual rendered ROI bitmap")
    }

    func testROIIdentityRejectsSettingsFileVersionAndCoverageMismatches() {
        let base = identity("a")
        var empty = ProcessedROIBitmapCache()
        XCTAssertNil(empty.value(for: base))
        XCTAssertNotEqual(base, identity("a", settings: "changed"))
        XCTAssertNotEqual(base, identity("a", version: "new-file"))
        XCTAssertNotEqual(base, identity("a", source: CGRect(x: 1, y: 0, width: 10, height: 10)))
        XCTAssertNotEqual(base, identity("a", backing: 2))
        XCTAssertNotEqual(base, identity("a", orientation: 6))
    }

    func testProductionServiceWarmHitUsesCompletedProcessedROIWithoutSecondRender() async throws {
        let count = RenderCounter()
        let request = requestForSyntheticROI()
        let service = ProcessedROICacheService { request in
            count.increment()
            let base = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
            let holder = BaseImageHolder(full: base, display: base, interactive: base, fullExtent: base.extent,
                displayExtent: base.extent, interactiveExtent: base.extent, baseTemperature: nil, baseTint: nil,
                baseExposure: nil, isRaw: false)
            guard let image = RAWImageLoader().renderProcessed(baseHolder: holder, cameraModel: request.cameraModel,
                    xmp: request.xmp, fullResolution: true, sourceRect: request.identity.sourceRect),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return ProcessedROIEntry(image: image, identity: request.identity, costBytes: cg.bytesPerRow * cg.height)
        }
        await service.prioritize([request])
        for _ in 0..<100 {
            if await service.cachedEntryCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let first = await service.cached(request)
        let second = await service.cached(request)
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.image === second?.image)
        await service.prioritize([request])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(count.value, 1, "the warm lookup returns the processed ROI without repeating render work")
    }

    func testProductionServiceDoesNotCacheUnsupportedDecodeFailure() async throws {
        let request = requestForSyntheticROI()
        let service = ProcessedROICacheService { _ in nil }
        await service.prioritize([request])
        try await Task.sleep(nanoseconds: 30_000_000)
        let count = await service.cachedEntryCount
        let bytes = await service.accountedBitmapBytes
        XCTAssertEqual(count, 0)
        XCTAssertEqual(bytes, 0)
    }

    func testProductionServiceOwnerTokenRejectsStaleReleaseAndCleansCurrentOwner() async {
        let service = ProcessedROICacheService { _ in nil }
        await service.foregroundStarted(owner: "selection-frame")
        await service.foregroundFinished(owner: "unsupported-render-ticket")
        let stillOwned = await service.foregroundOwnerID
        XCTAssertEqual(stillOwned, "selection-frame")
        await service.foregroundFinished(owner: "selection-frame")
        let released = await service.foregroundOwnerID
        XCTAssertNil(released)
    }

    func testProductionServiceKeepsCancelledUninterruptibleWorkerInActualRunningSlot() async throws {
        let gate = RendererGate()
        let first = requestForSyntheticROI()
        let second = requestForSyntheticROI(sourceRect: CGRect(x: 9, y: 6, width: 24, height: 20))
        let service = ProcessedROICacheService { _ in await gate.run(); return nil }
        await service.prioritize([first])
        for _ in 0..<100 where await gate.startedCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        var started = await gate.startedCount
        XCTAssertEqual(started, 1)
        await service.prioritize([second])
        try await Task.sleep(nanoseconds: 20_000_000)
        started = await gate.startedCount
        let active = await service.activeSpeculativeCount
        XCTAssertEqual(started, 1, "cancelled but executing work must keep the sole speculative slot")
        XCTAssertEqual(active, 1)
        await gate.releaseOne()
        for _ in 0..<100 where await gate.startedCount < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        started = await gate.startedCount
        let maximum = await gate.maximumConcurrent
        XCTAssertEqual(started, 2)
        XCTAssertEqual(maximum, 1)
        await gate.releaseOne()
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    func testRawDecodeGateBoundsActualSynchronousDecodeSectionsToOne() {
        let gate = RAWDecodeConcurrencyGate.shared
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            gate.withPermit { Thread.sleep(forTimeInterval: 0.005) }
        }
        XCTAssertEqual(gate.maximumConcurrent, 1, "foreground and cancelled speculative loader calls share one decode permit")
    }

    private func requestForSyntheticROI(sourceRect: CGRect = CGRect(x: 8, y: 6, width: 24, height: 20)) -> ProcessedROIRequest {
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/Users/kitleong/.hermes/cache/scratch/synthetic.jpg"))
        let roi = sourceRect
        let identity = ProcessedROIIdentity(assetID: asset.id, fileVersion: "fixture-v1", developSettings: "complete-settings",
            cameraModel: "fixture-camera", fullExtent: CGRect(x: 0, y: 0, width: 64, height: 48), sourceRect: roi,
            normalizedCenter: CGPoint(x: 0.5, y: 0.5), viewport: roi.size, backingScale: 2, orientation: 1)
        return ProcessedROIRequest(asset: asset, xmp: .empty, cameraModel: "fixture-camera", identity: identity)
    }

    private func identity(_ id: String, version: String = "v1", settings: String = "all-settings",
                          source: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10), backing: CGFloat = 1,
                          orientation: Int = 1) -> ProcessedROIIdentity {
        ProcessedROIIdentity(assetID: id, fileVersion: version, developSettings: settings, cameraModel: "model",
            fullExtent: CGRect(x: 0, y: 0, width: 100, height: 80), sourceRect: source,
            normalizedCenter: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 20, height: 20),
            backingScale: backing, orientation: orientation)
    }
}

private actor RendererGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startedCount = 0
    private(set) var activeCount = 0
    private(set) var maximumConcurrent = 0
    func run() async {
        startedCount += 1
        activeCount += 1
        maximumConcurrent = max(maximumConcurrent, activeCount)
        await withCheckedContinuation { waiters.append($0) }
        activeCount -= 1
    }
    func releaseOne() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
}

private final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}
