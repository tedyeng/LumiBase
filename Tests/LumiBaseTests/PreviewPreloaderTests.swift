import XCTest
@testable import LumiBase
import AppKit

final class PreviewPreloaderTests: XCTestCase {
    func testNeighborPlanUsesTravelPriorityWithinRadius() {
        XCTAssertEqual(
            PreviewPreloadPlan.neighborIndices(count: 12, selectedIndex: 5, direction: .forward, radius: 3),
            [6, 4, 7, 3, 8, 2]
        )
        XCTAssertEqual(
            PreviewPreloadPlan.neighborIndices(count: 12, selectedIndex: 5, direction: .backward, radius: 3),
            [4, 6, 3, 7, 2, 8]
        )
        XCTAssertEqual(
            PreviewPreloadPlan.neighborIndices(count: 4, selectedIndex: 0, direction: .forward, radius: 3),
            [1, 2, 3]
        )
    }

    func testCacheAccountsBytesEvictsLRUAndRejectsOversizedEntry() {
        var cache = PreviewBitmapCache<String>(capacityBytes: 100)
        cache.insert("A", forKey: "a", costBytes: 40)
        cache.insert("B", forKey: "b", costBytes: 40)
        XCTAssertEqual(cache.value(forKey: "a"), "A") // a is now least-recently used
        cache.insert("C", forKey: "c", costBytes: 70)
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.value(forKey: "c"), "C")
        XCTAssertEqual(cache.accountedBytes, 70)
        cache.insert("large", forKey: "large", costBytes: 101)
        XCTAssertNil(cache.value(forKey: "large"))
        XCTAssertLessThanOrEqual(cache.accountedBytes, 100)
    }

    func testCacheReservationLeavesRoomForInFlightBitmapAndPressurePurgeClearsSpeculation() {
        var cache = PreviewBitmapCache<String>(capacityBytes: 100)
        cache.insert("old", forKey: "old", costBytes: 40)
        XCTAssertTrue(cache.reserve(70))
        XCTAssertEqual(cache.accountedBytes, 0)
        cache.insert("new", forKey: "new", costBytes: 70)
        XCTAssertEqual(cache.accountedBytes, 70)
        cache.removeAll() // same operation used by memory-pressure and teardown handling
        XCTAssertEqual(cache.accountedBytes, 0)
        XCTAssertNil(cache.value(forKey: "new"))
    }

    func testCancelledRunningJobBlocksNextUntilItFinishesAndCannotPublish() throws {
        var scheduler = PreviewPreloadScheduler()
        scheduler.reprioritize(keys: ["a", "b"])
        let first = try XCTUnwrap(scheduler.beginNext())
        scheduler.reprioritize(keys: ["c", "d"])
        XCTAssertNil(scheduler.beginNext(), "cancelled work still occupies the sole worker until completion")
        XCTAssertFalse(scheduler.finish(first, mayPublish: true))
        let second = try XCTUnwrap(scheduler.beginNext())
        XCTAssertEqual(second.key, "c")
        XCTAssertTrue(scheduler.finish(second, mayPublish: true))
        XCTAssertEqual(scheduler.runningCount, 0)
    }

    func testExplicitCancellationAndGenerationRejectLateCompletion() throws {
        var scheduler = PreviewPreloadScheduler()
        scheduler.reprioritize(keys: ["old"])
        let old = try XCTUnwrap(scheduler.beginNext())
        scheduler.cancelAll()
        XCTAssertNil(scheduler.beginNext())
        XCTAssertFalse(scheduler.finish(old, mayPublish: true))
        XCTAssertEqual(scheduler.runningCount, 0)
    }

    func testPreviewKeyTracksCompleteDevelopRevisionDimensionsAndPipeline() {
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/preview.jpg"), dateModified: Date(timeIntervalSince1970: 10))
        let base = PreviewCacheKey(asset: asset, maxPixelSize: 1600, pipelineIdentity: "embedded-v1")
        var edited = asset
        edited.xmp.shadows2012 = 5
        let changedDevelop = PreviewCacheKey(asset: edited, maxPixelSize: 1600, pipelineIdentity: "embedded-v1")
        let changedSize = PreviewCacheKey(asset: asset, maxPixelSize: 800, pipelineIdentity: "embedded-v1")
        let changedPipeline = PreviewCacheKey(asset: asset, maxPixelSize: 1600, pipelineIdentity: "embedded-v2")
        XCTAssertNotEqual(base, changedDevelop)
        XCTAssertNotEqual(base, changedSize)
        XCTAssertNotEqual(base, changedPipeline)
    }

    func testEditedRAWIsSkippedInsteadOfSpeculativelyPublishingUnprocessedColor() {
        var raw = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/preview.nef"))
        XCTAssertTrue(PreviewPreloader.isSafeToSpeculate(raw))
        raw.xmp.exposure2012 = 1.0
        XCTAssertFalse(PreviewPreloader.isSafeToSpeculate(raw))
        let raster = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/preview.jpg"))
        XCTAssertTrue(PreviewPreloader.isSafeToSpeculate(raster))
    }

    func testSchedulerSkipsCachedKeysAndWaitsForMatchingForegroundCompletion() throws {
        var scheduler = PreviewPreloadScheduler()
        scheduler.reprioritize(keys: ["cached", "next"], cachedKeys: ["cached"])
        scheduler.suspendForForeground(selectionID: "selected")
        XCTAssertNil(scheduler.beginNext())
        scheduler.foregroundCompleted(selectionID: "other")
        XCTAssertNil(scheduler.beginNext(), "only the current selected asset may release speculation")
        scheduler.foregroundCompleted(selectionID: "selected")
        XCTAssertEqual(try XCTUnwrap(scheduler.beginNext()).key, "next")
    }

    func testPressurePolicyStaysSuspendedUntilNormal() {
        var policy = PreviewMemoryPressurePolicy()
        policy.receive(.warning)
        policy.receive(.critical)
        XCTAssertTrue(policy.isSuspended)
        policy.receive(.warning)
        XCTAssertTrue(policy.isSuspended)
        policy.receive(.normal)
        XCTAssertFalse(policy.isSuspended)
    }

    func testRAWThumbnailPolicyNeverFallsBackToFullImage() {
        XCTAssertEqual(PreviewPreloader.thumbnailOptions(isRaw: true)[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool, false)
        XCTAssertEqual(PreviewPreloader.thumbnailOptions(isRaw: true)[kCGImageSourceCreateThumbnailFromImageIfAbsent] as? Bool, false)
        XCTAssertEqual(PreviewPreloader.thumbnailOptions(isRaw: false)[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool, true)
    }

    @MainActor
    func testAppStateDefersListSnapshotUntilPublishedMutationCompletes() async throws {
        let state = AppState()
        let a = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        let b = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/b.jpg"))
        state.allAssets = [a]
        state.primarySelectedAssetID = a.id
        state.allAssets = [b]
        state.primarySelectedAssetID = b.id
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(state.previewSnapshotForTesting.assetIDs, [b.id])
        XCTAssertEqual(state.previewSnapshotForTesting.selectedID, b.id)
    }

    @MainActor
    func testAppStateRefreshAfterForegroundCompletionDoesNotRearmSameSelection() async throws {
        let preloader = PreviewPreloader(observeMemoryPressure: false)
        let state = AppState(preloader: preloader)
        let selected = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/selected.jpg"))
        let neighbor = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/neighbor.jpg"))
        state.allAssets = [selected]
        state.primarySelectedAssetID = selected.id
        try await Task.sleep(nanoseconds: 30_000_000)
        state.viewMode = .loupe
        try await Task.sleep(nanoseconds: 30_000_000)
        let initiallyPending = await preloader.hasPendingForegroundSelectionForTesting(selected.id)
        XCTAssertTrue(initiallyPending)

        // Model Loupe finishing its actual load before a deferred unrelated list refresh.
        await preloader.foregroundSelectionCompleted(selected.id)
        state.allAssets.append(neighbor)
        try await Task.sleep(nanoseconds: 30_000_000)

        let pendingAfterRefresh = await preloader.hasPendingForegroundSelectionForTesting(selected.id)
        XCTAssertFalse(pendingAfterRefresh)

        state.primarySelectedAssetID = neighbor.id
        try await Task.sleep(nanoseconds: 30_000_000)
        let pendingForNewSelection = await preloader.hasPendingForegroundSelectionForTesting(neighbor.id)
        XCTAssertTrue(pendingForNewSelection)
        await preloader.cancelAndClear()
    }

    @MainActor
    func testLateAppStateRefreshCannotRearmAlreadyCompletedLoupeRequest() async throws {
        let preloader = PreviewPreloader(observeMemoryPressure: false)
        let state = AppState(preloader: preloader)
        let selected = PhotoAsset(fileURL: URL(fileURLWithPath: "/tmp/late-selected.jpg"))
        state.allAssets = [selected]
        state.primarySelectedAssetID = selected.id
        state.viewMode = .loupe

        // Loupe can finish before AppState's yield-deferred published-state refresh.
        await preloader.foregroundSelectionStarted(selected.id)
        await preloader.foregroundSelectionCompleted(selected.id)
        try await Task.sleep(nanoseconds: 30_000_000)

        let pendingAfterLateRefresh = await preloader.hasPendingForegroundSelectionForTesting(selected.id)
        XCTAssertFalse(pendingAfterLateRefresh)
        await preloader.cancelAndClear()
    }

    func testActorDecodesSyntheticImageAndPublishesReusablePreview() async throws {
        func makeFixture() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.red.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 48, height: 32)).fill()
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
        let selectedURL = try makeFixture(), previewURL = try makeFixture()
        defer { try? FileManager.default.removeItem(at: selectedURL); try? FileManager.default.removeItem(at: previewURL) }
        let selected = PhotoAsset(fileURL: selectedURL), asset = PhotoAsset(fileURL: previewURL)
        let preloader = PreviewPreloader(observeMemoryPressure: false)
        await preloader.foregroundSelectionStarted(selected.id)
        await preloader.update(assets: [selected, asset], selectedID: selected.id, direction: .forward)
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeForegroundCompletion = await preloader.cachedPreview(for: asset)
        XCTAssertNil(beforeForegroundCompletion, "speculation waits for the selected foreground render")
        await preloader.handleMemoryPressure(.warning)
        await preloader.foregroundSelectionCompleted(selected.id)
        try await Task.sleep(nanoseconds: 30_000_000)
        let duringPressure = await preloader.cachedPreview(for: asset)
        XCTAssertNil(duringPressure, "foreground completion cannot bypass active memory pressure")
        await preloader.handleMemoryPressure(.normal)
        var cached: NSImage?
        for _ in 0..<100 {
            cached = await preloader.cachedPreview(for: asset)
            if cached != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(cached, "actor must decode the neighbor fixture and serve it to the Loupe consumer")
    }
}
