# Inspection 1.5.0: selection ownership and ROI cache checkpoint

## Change

The Loupe now associates every displayed frame and Fit fallback with a stable asset ID. Beginning selection advances the display generation and immediately clears the prior image, ROI provenance, and fallback. The body also gates rendering by current selected ID, closing the SwiftUI interval before the selection task runs. Thumbnail, Fit, native, and ROI publications require both the current ticket and matching asset ID. This rejects stale completion in A/B/A navigation and does not rely on filenames, which can be duplicated.

If a decode or render fails, the view displays an error/loading placeholder for the selected asset. It does not retain or label the previous photo as the new one. The native `NSView` surface remains in the hierarchy, so mouse capture and release behavior do not depend on image loading.

ROI rendering is on by default with its in-memory OFF switch retained. No preferences are read or mutated for the switch. Same-photo Fit fallback and full native frames remain available through the existing display transition code.

## RED/GREEN record

The ownership and default-toggle tests were added before production edits. RED was observed as compiler errors for the missing stable-owner API (`beginSelection(assetID:)`, owner-aware `accept`, and `owns`). The log is `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-red.log`. A second production transition test was added before its seam: the RED log reports missing `InspectionLoadTransition`, and the GREEN log records the passing test that drives the same synchronous transition Loupe uses before its first preload `await` (`inspection-1.5.0-selection-red.log` and `inspection-1.5.0-selection-green.log`).

The first GREEN attempt caught a missing `return` in the new ticket method; after correction and updating the old test that expected the wrong photo to remain visible, the focused suite passed **27 tests, 0 failures**. See `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-green.log`.

Full `swift test` passed **75 tests, 0 failures, 3 skipped** (opt-in context, ROI, and SSD benchmarks). See `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-tests.log`. The project-version metadata check first found build version 1.4.4, then passed with marketing/build version 1.5.0 and bundle ID `com.lumibase.LumiBase.Inspection.ROI`; see `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-version-red.log` and `inspection-1.5.0-version-green.log`.

Release `xcodebuild` succeeded. AppIntents metadata extraction was skipped because the target has no AppIntents dependency. Build log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-build.log`.

## Processed ROI neighboring cache

This iteration implements a completed processed ROI bitmap cache and one low-priority speculative worker. The cache admits at most three bitmaps and **128 MiB accounted bitmap bytes**. The byte count uses completed CGImage row stride × height; it is not an RSS cap, and transient decode/render allocations may exceed it.

Speculation uses a fresh `RAWImageLoader` instance and the same CIRAWFilter/ImageIO decode plus `AdobeColorPipeline` rendering path. Speculative loads bypass the loader cache and run at background priority. The worker serializes jobs, retains no decoded holder after render, and never calls `LiveDevelopPreviewEngine`. Foreground work clears pending speculation and invalidates any running result; the active slot remains occupied until uninterruptible RAW/Core Image work returns. This limits speculative work to one job and gives foreground work priority, but does not promise zero GPU contention.

Neighbor requests target the same normalized center, viewport, and backing scale at each adjacent image's oriented metadata extent. The immediately previous and next displayed assets are prioritized in travel direction. A neighbor is cached only when its decoded full extent matches the predicted extent and the requested source rectangle is fully covered. Unsupported metadata/decode/render cases are skipped without caching. Memory pressure clears the cache and pauses speculation until normal pressure returns.

Identity includes stable asset path, current resource identifier/file size/modification time, a sorted full XMP serialization, camera model, full extent, exact source rectangle, normalized center, viewport, backing scale, and orientation. Selection ownership/generation guards remain responsible for display publication; cache insertion from foreground render callbacks also checks the current render owner. Fit requests never look up or publish partial ROI frames.

The focused production seam tests exercise the actual processed renderer on a synthetic CI image, cache admission/eviction bounds, a service warm hit with exactly one render invocation, unsupported-render failure, settings/file/coverage/orientation/backing mismatches, worker count, reversal, and foreground invalidation. RED log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-roi-cache-red.log`; focused GREEN log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-roi-cache-focused.log`. Full Swift tests: **81 passed, 0 failures, 3 skipped** in `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-roi-cache-tests.log`. These demonstrate code-path reuse, not end-user timing or GUI smoothness.

The separate Release `xcodebuild` product uses marketing/build version 1.5.0 and bundle ID `com.lumibase.LumiBase.Inspection.ROI`. The verified app is `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.0-ROI.app`; build log is `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-roi-build.log`. Built/copied SHA-256 manifests are `inspection-1.5.0-roi-built-hashes.txt` and `inspection-1.5.0-roi-copied-hashes.txt` in `/Users/kitleong/.hermes/cache/scratch`.

Cold foreground RAW decode remains unchanged. No photos, sidecars, catalog data, or preferences were written. No GUI was launched and no GUI performance result is claimed.

## Review targets

Independent review should focus on `InspectionDisplay` ownership/generation transitions and `LoupeView.displayForSelectedAsset` plus all completion callbacks, then verify the ROI default and unchanged native input/capture routing. Check that the isolated release product uses both version fields 1.5.0 and the dedicated bundle ID.

The copied product at `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.0-ROI.app` reports marketing/build version 1.5.0 and the dedicated bundle identifier. Source and copied app file hash manifests match; see `inspection-1.5.0-built-hashes.txt` and `inspection-1.5.0-copied-hashes.txt` in scratch.

## Independent review blockers: follow-up

The concrete HIGH findings in `roi-cache-independent-review.txt` were reproduced and addressed in the production Loupe flow. Before the implementation, the new cache-hit transition test produced a compile-time RED because `InspectionCachedROITransition` did not exist; see `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-high-red.log`. The GREEN run exercises the same transition policy now used by `loadSelectedImage` and `updateProcessedImage`: cached ROI publication remains visible while the selected asset's full base holder is prepared; a Fit request made during preparation is carried forward and triggers a full Fit render as soon as that holder is ready. If holder preparation fails after Fit is requested, the selected asset's full preview is loaded and cached for Fit, but is never displayed over the ROI while zoomed. Holder readiness while still zoomed does not trigger a second native render. The thumbnail completion remains guarded from replacing an already displayed native frame.

Foreground ROI ownership now uses one lifecycle value for selection, render supersession, cancellation cleanup, unsupported native input, selection/decode failure, ROI OFF rendering, and view disappearance. Each release is conditional on the currently active token, so an older completion cannot release a newer render owner. Debounce/throttle cancellation paths release their render token, while the cache service independently checks token identity. The unsupported-native check finishes the still-current selection token before any render token is created.

Foreground and speculative `RAWImageLoader` calls now share one permit around synchronous ImageIO/CIRAWFilter decode and holder construction. A cancelled call that is already executing retains the permit until that synchronous section exits; waiting calls cannot start a second decode concurrently. This may delay foreground decode behind uninterruptible work already in progress. The focused regression run passed **5 tests, 0 failures** at `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-high-focused.log`. It covers the cache-hit-to-Fit transition and no-thumbnail-over-ROI fallback, stale/current foreground owner release, the shared decode permit, and a cancelled renderer held inside an uninterruptible suspension while another request is reprioritized. The actual active speculative slot remains one until the first invocation returns; maximum concurrent speculative renderer invocations observed was one. This does not claim zero foreground/speculative GPU contention: native RAW/Core Image rendering is not promptly interruptible. The cache ceiling remains **128 MiB accounted completed bitmap bytes** (row stride × height), not an RSS cap; temporary decode and render allocations can exceed it.

Full `swift test` passed **86 tests, 0 failures, 3 skipped** at `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-high-tests.log`. Release `xcodebuild` succeeded; only the expected AppIntents metadata extraction warning was emitted because this target has no AppIntents dependency. See `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-high-build.log`. The refreshed app at `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.0-ROI.app` reports marketing version 1.5.0, build version 1.5.0, and bundle ID `com.lumibase.LumiBase.Inspection.ROI`. Built and copied full-file SHA-256 manifests compare equal: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-high-built-hashes.txt` and `inspection-1.5.0-high-copied-hashes.txt`.

No GUI was launched or manually exercised. No photo, sidecar, catalog, or preference data was modified.

## Final targeted parent review

The follow-up review found that cached-ROI selection left `PreviewPreloader` foreground ownership active after the base-holder warmup completed while the view remained zoomed. The warmup now completes that owner when it can keep showing the cached native ROI. If Fit was requested during warmup, ownership remains foreground until the full Fit render or fallback completes. Holder failure with no pending Fit and either Fit fallback outcome also release the owner.

The warmup rechecks active develop settings after each suspended holder load and reloads the holder if those settings changed. An edit during warmup triggers a render with the current settings and revision rather than leaving the cached ROI or publishing a stale Fit render. Regression `testCachedROIHolderWarmupCompletesPreviewSelectionWhenStillZoomed` asserts release for the zoomed completion and retention for pending Fit.

The cache-hit-to-Fit path was rechecked: the cached ROI retains source-rectangle provenance until a full Fit image is accepted, and Fit does not request or publish a partial ROI as a full frame.

Final verification on 2026-09-22: `swift test` passed **87 tests, 0 failures, 3 opt-in benchmark skips**; log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-final-swift-tests.log`. Release `xcodebuild` succeeded with bundle ID `com.lumibase.LumiBase.Inspection.ROI` and version/build `1.5.0`; log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.0-final-xcodebuild.log`. The app at `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.0-ROI.app` was refreshed. Built and installed `Contents/MacOS/LumiBase` SHA-256 both equal `05b8c31a318af2fb7bda3c6223b55b0b9ae6290bf1cd5d6cb9d166ae6429ac6f`.
