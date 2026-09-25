import XCTest
import AppKit
import CoreImage
@testable import LumiBase

final class InspectionTests: XCTestCase {
    func testProducedPreviewKeepsNativeViewportGeometryAcrossHeldSelectionFitAndRepress() async throws {
        InspectionReadyFrameStore.shared.clearAll()
        defer { InspectionReadyFrameStore.shared.clearAll() }
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/private/tmp/preview-geometry-8192.jpg"))
        let selected = PhotoAsset(fileURL: URL(fileURLWithPath: "/private/tmp/preview-geometry-selected.jpg"))
        let xmp = XMPMetadata.empty
        let fullExtent = CGRect(x: 0, y: 0, width: 8192, height: 4096)
        var display = InspectionDisplay()
        var pendingSizes: [CGSize] = []
        var pendingPositions: [CGPoint] = []
        for previewWidth in [400, 1600] {
            InspectionReadyFrameStore.shared.clearPreviews()
            let previewHeight = previewWidth / 2
            let preloader = PreviewPreloader(observeMemoryPressure: false, previewDecoder: { _, _ in
                let bounds = CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
                guard let cg = CIContext().createCGImage(CIImage(color: .blue).cropped(to: bounds), from: bounds) else { return nil }
                return PreviewBitmap(image: cg, fullExtent: fullExtent)
            })
            await preloader.foregroundSelectionStarted(selected.id)
            await preloader.update(assets: [selected, asset], selectedID: selected.id, direction: .forward)
            await preloader.foregroundSelectionCompleted(selected.id)
            var producedFrame: InspectionReadyFrameStore.Frame?
            for _ in 0..<100 {
                producedFrame = PreviewPreloader.readyPreviewFrame(for: asset, xmp: xmp)
                if producedFrame != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let previewFrame = try XCTUnwrap(producedFrame, "worker must publish the synthetic preview before selection")
            XCTAssertEqual(previewFrame.image.width, previewWidth)
            XCTAssertEqual(previewFrame.fullExtent, fullExtent)
            let preview = NSImage(cgImage: previewFrame.image, size: NSSize(width: previewWidth, height: previewHeight))

            var ticket = InspectionLoadTransition.beginSelection(for: asset, display: &display)
            let handoff = try XCTUnwrap(InspectionReadyFrameHandoff.current(for: asset, xmp: xmp, display: display,
                zoomed: true, center: CGPoint(x: 0.7, y: 0.4), viewport: CGSize(width: 900, height: 700), backing: 2,
                allowROI: false))
            display.accept(handoff.image, assetID: asset.id, filename: asset.filename,
                pixels: handoff.sourceRect?.size ?? handoff.image.size, native: handoff.native, ticket: ticket,
                sourceRect: handoff.sourceRect, fullExtent: handoff.fullExtent)
            XCTAssertEqual(handoff.provenance, "current-preview-native-pending")
            let pending = InspectionFrameLayout.make(pixels: display.pixels, sourceRect: display.sourceRect,
                fullExtent: display.fullExtent, zoomed: true, viewport: CGSize(width: 900, height: 700), backing: 2)
            XCTAssertEqual(pending.imageSize, CGSize(width: 4096, height: 2048),
                           "held 100% preview must use original dimensions, regardless of 400/1600 proxy size")
            XCTAssertEqual(display.fullExtent, fullExtent)
            pendingSizes.append(pending.imageSize)
            var heldState = InspectionState()
            heldState.persistent = true
            heldState.center = CGPoint(x: 0.7, y: 0.4)
            heldState.clamp(displayed: pending.clampSize, viewport: CGSize(width: 900, height: 700))
            let pendingPosition = pending.imagePosition(viewport: CGSize(width: 900, height: 700),
                center: heldState.center, sourceRect: display.sourceRect)
            pendingPositions.append(pendingPosition)

            let fit = InspectionFrameLayout.make(pixels: preview.size, sourceRect: nil, fullExtent: fullExtent,
                zoomed: false, viewport: CGSize(width: 900, height: 700), backing: 2)
            XCTAssertLessThanOrEqual(fit.imageSize.width, 900)
            XCTAssertLessThanOrEqual(fit.imageSize.height, 700)

            display.restoreFullFit()
            ticket = display.beginSelection(assetID: asset.id, filename: asset.filename)
            let native = NSImage(size: NSSize(width: 8192, height: 4096))
            display.accept(native, assetID: asset.id, filename: asset.filename, pixels: fullExtent.size,
                native: true, ticket: ticket, fullExtent: fullExtent)
            let repressed = InspectionFrameLayout.make(pixels: display.pixels, sourceRect: display.sourceRect,
                fullExtent: display.fullExtent, zoomed: true, viewport: CGSize(width: 900, height: 700), backing: 2)
            XCTAssertEqual(repressed.imageSize, pending.imageSize,
                           "native completion must retain the preview's center and 100% scale")
            XCTAssertEqual(repressed.imagePosition(viewport: CGSize(width: 900, height: 700),
                center: heldState.center, sourceRect: display.sourceRect), pendingPosition,
                "native completion must retain the selected center's viewport position")
            XCTAssertTrue(display.native)
            await preloader.cancelAndClear()
        }
        XCTAssertEqual(pendingSizes[0], pendingSizes[1])
        XCTAssertEqual(pendingPositions[0], pendingPositions[1])
    }

    func testUnknownPreviewExtentUsesFitFallbackWithoutTreatingProxyAsNativeGeometry() throws {
        InspectionReadyFrameStore.shared.clearAll()
        defer { InspectionReadyFrameStore.shared.clearAll() }
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/private/tmp/preview-unknown-extent.jpg"))
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let cg = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        InspectionReadyFrameStore.shared.publishFullPreview(asset: asset, xmp: .empty, image: image, fullExtent: .zero)
        var display = InspectionDisplay()
        let ticket = display.beginSelection(assetID: asset.id, filename: asset.filename)
        let handoff = try XCTUnwrap(InspectionReadyFrameHandoff.current(for: asset, xmp: .empty, display: display,
            zoomed: true, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 700), backing: 2,
            allowROI: false))
        display.accept(handoff.image, assetID: asset.id, filename: asset.filename, pixels: handoff.image.size,
            native: false, ticket: ticket, fullExtent: handoff.fullExtent)
        XCTAssertTrue(display.fullExtent.isEmpty)
        let layout = InspectionFrameLayout.make(pixels: display.pixels, sourceRect: nil, fullExtent: display.fullExtent,
            zoomed: true, viewport: CGSize(width: 900, height: 700), backing: 2)
        XCTAssertLessThanOrEqual(layout.imageSize.width, 900)
        XCTAssertLessThanOrEqual(layout.imageSize.height, 700)
    }

    func testCachedROIRequiresDecodedHolderExtentToMatchIncludingOriginAndOrientationGeometry() {
        let portraitExtent = CGRect(x: -21, y: 47, width: 4200, height: 8000)
        var transition = InspectionCachedROITransition()
        _ = transition.publishCachedROI(fullExtent: portraitExtent)
        XCTAssertEqual(transition.baseHolderPrepared(isZoomed: true, holderFullExtent: portraitExtent), .keepCachedNativeROI)

        var mismatch = InspectionCachedROITransition()
        _ = mismatch.publishCachedROI(fullExtent: portraitExtent)
        XCTAssertEqual(mismatch.baseHolderPrepared(isZoomed: true,
            holderFullExtent: CGRect(x: -21, y: 47, width: 4000, height: 8000)), .renderCurrentNative,
            "a warmed holder with different oriented full extent must trigger a fresh render")
        XCTAssertFalse(InspectionCachedROITransition.matchesKnownExtent(.zero, .zero))
    }

    @MainActor
    func testRapidFolderSwitchUsesBackgroundQuickScanAndRejectsStaleABACompletion() async throws {
        let root = URL(fileURLWithPath: "/Users/kitleong/.hermes/cache/scratch/lumibase-folder-switch-1.5.4/synthetic", isDirectory: true)
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        let scanner = ControlledFolderScanGate()
        let decoder = ControlledFolderDecodeGate()
        let quickScanThreads = FolderQuickScanThreadRecorder()
        let state = AppState(
            preloader: PreviewPreloader(observeMemoryPressure: false),
            quickFolderScan: { _ in quickScanThreads.record(Thread.isMainThread); return [] },
            fullFolderScan: { url in
                let scanned = await scanner.scan(url: url)
                return await decoder.decode(assets: scanned)
            }
        )

        state.openFolder(url: folderA)
        await scanner.waitForCalls(1)
        state.openFolder(url: folderB)
        await scanner.waitForCalls(2)
        state.openFolder(url: folderA)
        await scanner.waitForCalls(3)

        XCTAssertEqual(quickScanThreads.mainThreadCallCount, 0,
                       "folder listing and per-file metadata lookups must not run on the main actor")

        await scanner.resolve(call: 2, with: [PhotoAsset(fileURL: folderA.appendingPathComponent("latest-A.jpg"))])
        await decoder.waitForCalls(1)
        await decoder.resolve(call: 0)
        for _ in 0..<100 { if state.allAssets.first?.filename == "latest-A.jpg" { break }; await Task.yield() }
        XCTAssertEqual(state.allAssets.first?.filename, "latest-A.jpg")

        await scanner.resolve(call: 1, with: [PhotoAsset(fileURL: folderB.appendingPathComponent("stale-B.jpg"))])
        await decoder.waitForCalls(2)
        await decoder.resolve(call: 1)
        await scanner.resolve(call: 0, with: [PhotoAsset(fileURL: folderA.appendingPathComponent("stale-A.jpg"))])
        await decoder.waitForCalls(3)
        await decoder.resolve(call: 2)
        for _ in 0..<100 { if state.allAssets.first?.filename == "stale-A.jpg" { break }; await Task.yield() }
        XCTAssertEqual(state.currentFolderURL, folderA)
        XCTAssertEqual(state.allAssets.first?.filename, "latest-A.jpg",
                       "the first A scan must not replace results from the latest A generation")
        let cancelledScans = await scanner.cancelledCalls
        XCTAssertEqual(cancelledScans, Set([0, 1]),
                       "switching folders must cancel both obsolete scans, including the earlier A request")
        let cancelledDecodes = await decoder.cancelledCalls
        XCTAssertEqual(cancelledDecodes, Set([1, 2]),
                       "late decode completions must observe cancellation and remain unpublished")
    }

    @MainActor
    func testDelayedCachedROIQueryRejectsDevelopSettingsChangedWhileSuspended() async throws {
        let gate = CachedROIQueryGate()
        let load = UUID(), render = UUID()
        let captured = InspectionCachedROIPublicationState(assetID: "photo-A", loadRevision: load,
            renderRevision: render, developSettings: "old-exposure-temp", zoomed: true, roiEnabled: true,
            center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 700), backingScale: 2)
        var current = captured
        let task = Task { @MainActor in
            await InspectionCachedROIPublication.lookup(captured: captured, current: { current }) {
                await gate.query()
            }
        }
        await gate.waitUntilStarted()
        current.developSettings = "new-exposure-temp"
        await gate.resolve("old-cached-bitmap")
        let published = await task.value
        XCTAssertNil(published, "a cached ROI rendered with old exposure/temperature must never publish after current settings change")
    }

    @MainActor
    func testDelayedCachedROIQueryRejectsSelectionA_B_AAndChangedROIRequestGeometry() async throws {
        let gate = CachedROIQueryGate()
        let captured = InspectionCachedROIPublicationState(assetID: "photo-A", loadRevision: UUID(),
            renderRevision: UUID(), developSettings: "settings-A", zoomed: true, roiEnabled: true,
            center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 700), backingScale: 2)
        var current = captured
        let task = Task { @MainActor in
            await InspectionCachedROIPublication.lookup(captured: captured, current: { current }) {
                await gate.query()
            }
        }
        await gate.waitUntilStarted()
        // The selected ID returns to A, but a fresh selection ticket must still invalidate A's old lookup.
        current.assetID = "photo-B"
        current.assetID = "photo-A"
        current.loadRevision = UUID()
        current.center = CGPoint(x: 0.7, y: 0.5)
        await gate.resolve("stale-ROI")
        let published = await task.value
        XCTAssertNil(published, "A/B/A and panned ROI geometry must invalidate the old cache result")
    }

    func testDeferredDevelopObserverResolvesCurrentSettingsInsteadOfQueuedPayload() {
        let queuedOldValue = "old-photo-settings"
        let currentValue = "selected-photo-settings"
        let resolved = InspectionCachedROIPublication.resolveDeferredDevelopUpdate(captured: queuedOldValue) { currentValue }
        XCTAssertEqual(resolved, currentValue, "a deferred observer must read current selection settings when its main-queue block runs")
    }

    @MainActor
    func testDelayedCachedROIQueryKeepsFastHitWhenAllInputsRemainCurrent() async throws {
        let gate = CachedROIQueryGate()
        let captured = InspectionCachedROIPublicationState(assetID: "photo-A", loadRevision: UUID(),
            renderRevision: UUID(), developSettings: "settings-A", zoomed: true, roiEnabled: true,
            center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 700), backingScale: 2)
        let task = Task { @MainActor in
            await InspectionCachedROIPublication.lookup(captured: captured, current: { captured }) {
                await gate.query()
            }
        }
        await gate.waitUntilStarted()
        await gate.resolve("valid-cached-bitmap")
        let published = await task.value
        XCTAssertEqual(published, "valid-cached-bitmap", "an unchanged cache identity retains the existing immediate-hit path")
    }

    func testRejectedCachedROIContinuesWithCurrentDevelopSettings() {
        let capturedOldSettings = "cached-with-old-white-balance"
        let currentSettings = "current-white-balance-and-exposure"
        let decodeSettings = InspectionCachedROIPublication.resolveDeferredDevelopUpdate(captured: capturedOldSettings) { currentSettings }
        XCTAssertEqual(decodeSettings, currentSettings, "a rejected ROI lookup must decode the holder with current active settings")
    }

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

    func testSamePhotoSettingsEditRetainsLastValidFrameAndMarksItStaleForUpdating() {
        var display = InspectionDisplay()
        let ticket = display.beginSelection(assetID: "same-photo", filename: "photo.jpg")
        let oldSettings = "settings-r1", newSettings = "settings-r2"
        let frame = NSImage(size: NSSize(width: 640, height: 480))
        display.accept(frame, assetID: "same-photo", filename: "photo.jpg", pixels: frame.size,
                       native: false, ticket: ticket, developSettingsIdentity: oldSettings)

        let updating = display.presentation(for: "same-photo", settingsIdentity: newSettings)
        XCTAssertTrue(updating.image === frame, "same-photo edits keep the last valid displayed bitmap during the exact-settings render")
        XCTAssertFalse(updating.settingsCurrent, "retained pixels must not be labeled as current settings")
        let otherPhoto = display.presentation(for: "another-photo", settingsIdentity: newSettings)
        XCTAssertNil(otherPhoto.image, "a retained frame never crosses photo ownership")
    }

    @MainActor
    func testActualPreviewPreloaderPublishesCurrentFitFrameBeforeSelectionAsyncLoad() async throws {
        InspectionReadyFrameStore.shared.clearAll()
        let root = inspectionTestScratchURL("fixtures").deletingLastPathComponent().appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let anchorURL = root.appendingPathComponent("anchor.jpg")
        let selectedURL = root.appendingPathComponent("selected.jpg")
        try fixtureJPEG().write(to: anchorURL, options: .atomic)
        try fixtureJPEG().write(to: selectedURL, options: .atomic)
        let anchor = PhotoAsset(fileURL: anchorURL, fileSize: 1)
        let selected = PhotoAsset(fileURL: selectedURL, fileSize: 1,
                                  xmp: XMPMetadata(exposure2012: 0.25, highlights2012: -100))
        let preloader = PreviewPreloader(observeMemoryPressure: false)
        await preloader.update(assets: [anchor, selected], selectedID: anchor.id, direction: .forward)
        var produced: CGImage?
        for _ in 0..<200 {
            produced = await preloader.cachedPreview(for: selected)
            if produced != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(produced, "the real ImageIO preload worker must publish before selection")

        var display = InspectionDisplay()
        _ = InspectionLoadTransition.beginSelection(for: selected, display: &display)
        XCTAssertNil(display.image, "selection clears previous ownership before rendering")
        let handoff = InspectionReadyFrameHandoff.current(for: selected, xmp: selected.xmp, display: display,
            zoomed: false, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 600), backing: 2)
        XCTAssertEqual(handoff?.provenance, "preloaded-preview")
        XCTAssertEqual(handoff?.image.size.width, produced.map { CGFloat($0.width) })
        XCTAssertEqual(handoff?.image.size.height, produced.map { CGFloat($0.height) })
        XCTAssertLessThanOrEqual(InspectionReadyFrameStore.shared.accountedBytes, InspectionReadyFrameStore.budgetBytes)
        let firstFrameTicket = InspectionLoadTransition.beginSelection(for: selected, display: &display)
        if let handoff {
            display.accept(handoff.image, assetID: selected.id, filename: selected.filename, pixels: handoff.image.size,
                           native: false, ticket: firstFrameTicket, fullExtent: handoff.fullExtent)
        }
        XCTAssertTrue(display.owns(assetID: selected.id))
        XCTAssertNotNil(display.image, "the producer's bitmap becomes the first selected display frame without a loader await")

        var staleSettings = selected.xmp; staleSettings.highlights2012 = -80
        XCTAssertNil(InspectionReadyFrameHandoff.current(for: selected, xmp: staleSettings, display: display,
            zoomed: false, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 600), backing: 2),
            "complete settings identity rejects a warm frame from a different edit revision")
        let cold = PhotoAsset(fileURL: root.appendingPathComponent("cold.jpg"))
        XCTAssertNil(InspectionReadyFrameHandoff.current(for: cold, xmp: cold.xmp, display: display,
            zoomed: false, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 600), backing: 2))
        XCTAssertNil(InspectionReadyFrameHandoff.current(for: anchor, xmp: anchor.xmp, display: display,
            zoomed: false, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 600), backing: 2),
            "a different selected owner cannot borrow another ready frame")
        await preloader.handleMemoryPressure(.critical)
        XCTAssertEqual(InspectionReadyFrameStore.shared.accountedBytes, 0, "pressure clears the unified consumer-visible store")
        XCTAssertNil(InspectionReadyFrameHandoff.current(for: selected, xmp: selected.xmp, display: display,
            zoomed: false, center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 900, height: 600), backing: 2))
        await preloader.cancelAndClear()
    }

    private func fixtureJPEG() throws -> Data {
        let color = CIColor(red: 0.2, green: 0.6, blue: 0.9)
        let ci = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let cg = try XCTUnwrap(context.createCGImage(ci, from: ci.extent))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:]))
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
        let root = inspectionTestScratchURL(UUID().uuidString)
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

private actor CachedROIQueryGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiter: CheckedContinuation<String?, Never>?

    func query() async -> String? {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { resultWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resolve(_ result: String?) {
        resultWaiter?.resume(returning: result)
        resultWaiter = nil
    }
}

private actor ControlledFolderScanGate {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<[PhotoAsset], Never>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var cancelledCalls: Set<Int> = []

    func scan(url: URL) async -> [PhotoAsset] {
        let call = callCount
        let result = await withCheckedContinuation { continuation in
            callCount += 1
            pending[call] = continuation
            let ready = countWaiters.filter { callCount >= $0.0 }
            countWaiters.removeAll { callCount >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
        if Task.isCancelled { cancelledCalls.insert(call) }
        return result
    }

    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func resolve(call: Int, with assets: [PhotoAsset]) {
        pending.removeValue(forKey: call)?.resume(returning: assets)
    }
}

private actor ControlledFolderDecodeGate {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var cancelledCalls: Set<Int> = []

    func decode(assets: [PhotoAsset]) async -> [PhotoAsset] {
        let call = callCount
        await withCheckedContinuation { continuation in
            callCount += 1
            pending[call] = continuation
            let ready = countWaiters.filter { callCount >= $0.0 }
            countWaiters.removeAll { callCount >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
        if Task.isCancelled { cancelledCalls.insert(call) }
        return assets
    }

    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func resolve(call: Int) {
        pending.removeValue(forKey: call)?.resume()
    }
}

private final class FolderQuickScanThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadCalls = 0
    func record(_ isMainThread: Bool) {
        guard isMainThread else { return }
        lock.lock(); mainThreadCalls += 1; lock.unlock()
    }
    var mainThreadCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return mainThreadCalls
    }
}
