import XCTest
import AppKit
@testable import LumiBase

final class ProcessedROICacheTests: XCTestCase {
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

    func testROIIdentityRejectsSettingsFileVersionAndCoverageMismatches() {
        let base = identity("a")
        XCTAssertNotEqual(base, identity("a", settings: "changed"))
        XCTAssertNotEqual(base, identity("a", version: "new-file"))
        XCTAssertNotEqual(base, identity("a", source: CGRect(x: 1, y: 0, width: 10, height: 10)))
        XCTAssertNotEqual(base, identity("a", backing: 2))
        XCTAssertNotEqual(base, identity("a", orientation: 6))
    }

    func testSharedPreviewAndROIBudgetAccountsMixLruOversizeReplacementAndPressure() async throws {
        let store = InspectionReadyFrameStore.shared
        store.clearAll()
        defer { store.clearAll() }
        let cg = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            from: CGRect(x: 0, y: 0, width: 2, height: 2)))
        let image = InspectionReadyFrameStore.Frame(image: cg, kind: .fullPreview,
            fullExtent: CGRect(x: 0, y: 0, width: 2, height: 2), sourceRect: nil, bytes: 40 * 1024 * 1024)
        let previewA = PreviewCacheKey(asset: PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), maxPixelSize: 2, pipelineIdentity: "test")
        let previewB = PreviewCacheKey(asset: PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/b.jpg")), maxPixelSize: 2, pipelineIdentity: "test")
        let previewC = PreviewCacheKey(asset: PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/c.jpg")), maxPixelSize: 2, pipelineIdentity: "test")
        let req = requestForSyntheticROI()
        let roiKey = InspectionReadyFrameStore.Key.roi(req.identity)
        let roiFrame = InspectionReadyFrameStore.Frame(image: cg, kind: .nativeROI,
            fullExtent: req.identity.fullExtent, sourceRect: req.identity.sourceRect, bytes: 64 * 1024 * 1024)

        XCTAssertTrue(store.publish(image, for: .preview(previewA)))
        XCTAssertTrue(store.publish(roiFrame, for: roiKey))
        XCTAssertEqual(store.accountedBytes, 104 * 1024 * 1024, "preview and ROI bytes share one accounted budget")
        _ = store.roi(assetID: req.identity.assetID, fileVersion: req.identity.fileVersion,
            settings: req.identity.developSettings, cameraModel: req.identity.cameraModel,
            center: req.identity.normalizedCenter, viewport: req.identity.viewport,
            backing: req.identity.backingScale, orientation: req.identity.orientation) // refresh ROI LRU
        let halfBudget = InspectionReadyFrameStore.Frame(image: cg, kind: .fullPreview,
            fullExtent: .zero, sourceRect: nil, bytes: 60 * 1024 * 1024)
        XCTAssertTrue(store.publish(halfBudget, for: .preview(previewB)))
        XCTAssertNil(store.preview(for: previewA), "least-recently-used preview is evicted to admit a mixed-store publication")
        XCTAssertNotNil(store.preview(for: previewB))

        XCTAssertTrue(store.publish(image, for: .preview(previewB)), "replacement publication is admitted")
        XCTAssertEqual(store.accountedBytes, 40 * 1024 * 1024 + 64 * 1024 * 1024, "replacing an entry subtracts its prior accounted cost")
        let oversized = InspectionReadyFrameStore.Frame(image: cg, kind: .fullPreview,
            fullExtent: .zero, sourceRect: nil, bytes: InspectionReadyFrameStore.budgetBytes + 1)
        XCTAssertFalse(store.publish(oversized, for: .preview(previewC)), "oversized entry is rejected without evicting valid entries")
        XCTAssertNotNil(store.preview(for: previewB))

        let asset = req.asset
        XCTAssertTrue(store.publish(image, for: .preview(PreviewCacheKey(asset: asset, maxPixelSize: 1600,
            pipelineIdentity: "imageio-embedded-transformed-rgba-v1"))))
        XCTAssertNotNil(InspectionReadyFrameHandoff.current(for: asset, xmp: req.xmp, display: InspectionDisplay(),
            zoomed: false, center: req.identity.normalizedCenter, viewport: req.identity.viewport,
            backing: req.identity.backingScale), "the real synchronous consumer sees the shared-store publication")
        let preloader = PreviewPreloader(observeMemoryPressure: false)
        await preloader.handleMemoryPressure(.warning)
        XCTAssertEqual(store.accountedBytes, 0, "memory pressure synchronously removes frames visible to the consumer")
        XCTAssertNil(InspectionReadyFrameHandoff.current(for: asset, xmp: req.xmp, display: InspectionDisplay(),
            zoomed: false, center: req.identity.normalizedCenter, viewport: req.identity.viewport,
            backing: req.identity.backingScale), "pressure-purged bitmap cannot be handed to the viewer")
    }

    func testSharedROIMatcherRequiresActualOrientationAndKeepsNonzeroPortraitExtent() throws {
        let store = InspectionReadyFrameStore.shared
        store.clearAll()
        defer { store.clearAll() }
        let request = requestForSyntheticROI()
        let identity = ProcessedROIIdentity(assetID: request.identity.assetID,
            fileVersion: request.identity.fileVersion, developSettings: request.identity.developSettings,
            cameraModel: request.identity.cameraModel, fullExtent: CGRect(x: -17, y: 33, width: 1800, height: 4200),
            sourceRect: InspectionROI.sourceRect(extent: CGRect(x: -17, y: 33, width: 1800, height: 4200),
                center: request.identity.normalizedCenter, viewport: request.identity.viewport, backing: request.identity.backingScale),
            normalizedCenter: request.identity.normalizedCenter, viewport: request.identity.viewport,
            backingScale: request.identity.backingScale, orientation: 6)
        let cg = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            from: CGRect(x: 0, y: 0, width: 2, height: 2)))
        let frame = InspectionReadyFrameStore.Frame(image: cg, kind: .nativeROI, fullExtent: identity.fullExtent,
            sourceRect: identity.sourceRect, bytes: 16)
        XCTAssertTrue(store.publish(frame, for: .roi(identity)))
        let query = { (orientation: Int) in store.roi(assetID: identity.assetID, fileVersion: identity.fileVersion,
            settings: identity.developSettings, cameraModel: identity.cameraModel, center: identity.normalizedCenter,
            viewport: identity.viewport, backing: identity.backingScale, orientation: orientation) }
        XCTAssertNil(query(1), "landscape/default orientation cannot accept a cached portrait orientation 6 ROI")
        XCTAssertNotNil(query(6), "actual portrait source orientation matches")
        XCTAssertEqual(query(6)?.fullExtent, identity.fullExtent, "nonzero origin and portrait extent survive the lookup")
    }

    func testProductionServiceWarmHitUsesCompletedProcessedROIWithoutSecondRender() async throws {
        InspectionReadyFrameStore.shared.clearAll()
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
            return ProcessedROIEntry(image: cg, identity: request.identity, costBytes: cg.bytesPerRow * cg.height)
        }
        await service.prioritize([request])
        for _ in 0..<100 {
            if await service.cachedEntryCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let first = await service.cached(request)
        let second = await service.cached(request)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.image.width, second?.image.width)
        var display = InspectionDisplay()
        _ = display.beginSelection(assetID: request.asset.id, filename: request.asset.filename)
        let base = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9)).cropped(to: request.identity.fullExtent)
        let holder = BaseImageHolder(full: base, display: base, interactive: base, fullExtent: base.extent,
            displayExtent: base.extent, interactiveExtent: base.extent, baseTemperature: nil, baseTint: nil,
            baseExposure: nil, isRaw: false)
        let fullPreview = try XCTUnwrap(RAWImageLoader().renderProcessed(baseHolder: holder,
            cameraModel: request.cameraModel, xmp: request.xmp, fullResolution: false, sourceRect: nil))
        InspectionReadyFrameStore.shared.publishFullPreview(asset: request.asset, xmp: request.xmp,
            image: fullPreview, fullExtent: request.identity.fullExtent)
        let native = InspectionReadyFrameHandoff.current(for: request.asset, xmp: request.xmp, display: display,
            zoomed: true, center: request.identity.normalizedCenter, viewport: request.identity.viewport,
            backing: request.identity.backingScale)
        XCTAssertEqual(native?.provenance, "processed-roi", "the real ROI service producer must reach synchronous selection")
        XCTAssertEqual(native?.sourceRect, request.identity.sourceRect)
        if let native {
            let selectedTicket = display.beginSelection(assetID: request.asset.id, filename: request.asset.filename)
            display.accept(native.image, assetID: request.asset.id, filename: request.asset.filename,
                pixels: native.sourceRect?.size ?? .zero, native: native.native,
                ticket: selectedTicket,
                sourceRect: native.sourceRect, fullExtent: native.fullExtent)
        }
        XCTAssertTrue(display.native)
        XCTAssertEqual(display.sourceRect, request.identity.sourceRect)
        var mismatchDisplay = InspectionDisplay()
        _ = mismatchDisplay.beginSelection(assetID: request.asset.id, filename: request.asset.filename)
        let mismatch = InspectionReadyFrameHandoff.current(for: request.asset, xmp: request.xmp, display: mismatchDisplay,
            zoomed: true, center: CGPoint(x: 0.7, y: 0.5), viewport: request.identity.viewport,
            backing: request.identity.backingScale)
        XCTAssertEqual(mismatch?.provenance, "current-preview-native-pending",
                       "geometry mismatch may show the selected full preview while current native work is pending")
        await service.prioritize([request])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(count.value, 1, "the warm lookup returns the processed ROI without repeating render work")
    }

    func testProductionServiceDoesNotCacheUnsupportedDecodeFailure() async throws {
        InspectionReadyFrameStore.shared.clearAll()
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
        let xmp = XMPMetadata(highlights2012: -100)
        let asset = PhotoAsset(fileURL: inspectionTestScratchURL("synthetic.jpg"),
            fileSize: 42, dateModified: Date(timeIntervalSince1970: 100), sourceOrientation: 1, xmp: xmp)
        let full = CGRect(x: 0, y: 0, width: 64, height: 48)
        let center = CGPoint(x: 0.5, y: 0.5), viewport = CGSize(width: 12, height: 10), backing: CGFloat = 2
        let roi = InspectionROI.sourceRect(extent: full, center: center, viewport: viewport, backing: backing)
        let identity = ProcessedROIIdentity(assetID: asset.id, fileVersion: ProcessedROIRequest.fileVersion(for: asset),
            developSettings: ProcessedROIRequest.settingsIdentity(xmp), cameraModel: "", fullExtent: full, sourceRect: roi,
            normalizedCenter: center, viewport: viewport, backingScale: backing, orientation: 1)
        return ProcessedROIRequest(asset: asset, xmp: xmp, cameraModel: nil, identity: identity)
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
