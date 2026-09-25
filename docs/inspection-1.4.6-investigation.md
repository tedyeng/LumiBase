# Inspection 1.4.6 ROI stutter investigation

## Checkpoint

No performance fix is claimed. Static tracing shows a plausible serialized-renderer stall after release, but this checkout has not reproduced the user's GUI symptom or measured renderer occupancy on the target photo set. The new path-free `com.lumibase.inspection/trace` events are capped at 600 per process and distinguish accepted native downs, hold state, zoom transitions, revision/debounce cancellation, renderer start/completion, stale publication rejection, and preview-preloader cache/scheduling outcomes. No image or photo paths are included in these new events.

## Trace through the current implementation

1. `InspectionSurface.mouseDown` accepts a point in its bounds, calls the owner immediately, then records the capture point. The owner calls `InspectionState.begin`, setting `held = true`; this is evidence of an accepted press, independent of whether pixels finish rendering.
2. `is100PercentZoom` is derived from `persistent || held`. SwiftUI's `onChange` issues a new render revision and calls `updateProcessedImage` when it changes.
3. With ROI enabled, native requests wait 25 ms before asking `LiveDevelopPreviewEngine` to render. Each pan updates the center and issues a new revision, cancelling the pending task; the source holder is looked up again before the request (the RAW holder cache may return it immediately for the same URL and WB settings).
4. Release sets `held = false`. If not persistent, the zoom `onChange` restores `InspectionDisplay.lastFullFit`, but also calls `updateProcessedImage`. Fit submits an interactive render immediately and schedules a display-quality render after 200 ms.
5. The engine has one serial queue and one current synchronous render. New requests replace only the pending request; they cannot interrupt a render already executing. Revision checks reject obsolete completions at publication, but do not recover the compute time spent on an obsolete Fit render. A fast re-press can therefore have its native ROI request waiting behind an accepted Fit render. This is the highest-ranked code-level explanation for delayed pixels after an accepted press, not proof that the renderer explains the report.
6. Monitor release and AppKit `mouseUp` are guarded/idempotent through `lastPoint`; cancel, app deactivation, window transitions, and teardown release an active hold. A short second click toggles persistent zoom only on release. Existing native tests cover these methods and state transitions, but do not drive SwiftUI `onChange` into a controllable renderer.

## Ranked hypotheses

1. **Obsolete release-to-Fit work occupies the renderer.** Strongest structural candidate: Fit schedules an immediate proxy and a delayed full render; invalidated tickets prevent publication but cannot stop current synchronous work. Requires a controlled-renderer integration test or runtime trace timing to confirm it as the user's cause.
2. **ROI debounce and center changes delay publication.** ROI waits 25 ms, and drag-driven center updates cancel and replace pending requests. Likely to amplify stutter during movement; it does not explain a down that never sets `held`.
3. **A native input/capture edge drops a down or release.** Lower rank because in-bounds `mouseDown` calls the owner unconditionally and the existing method tests cover capture, outside release, wheel, cancellation, and double-click cases. No GUI acceptance is inferred from those tests.
4. **Stale full-native early return.** Not supported for ROI frames: the reuse predicate explicitly rejects frames with a `sourceRect`. A full native frame may be reused while persistent zoom remains on, which is the intended fast path.
5. **No retained same-location ROI result.** Re-entry can repeat native processing. This is a possible cost, but no evidence yet justifies adding a bitmap cache; no broader decode/cache expansion is warranted.

## Preload and image cache scope

- `PreviewPreloader` speculates up to three adjacent previews in travel-priority order, uses a single low-priority worker, and has a 128 MiB accounted bitmap LRU at 1600 px. Foreground selection and memory pressure pause it; edited RAW assets are skipped. This path can help a later Fit/thumbnail request if that asset's preview was cached.
- It does not submit native or ROI work to `LiveDevelopPreviewEngine`, does not cache full-resolution RAW pixels or processed ROI frames, and cannot unblock the engine's serial render queue. It is not an explanation for native re-entry queue delay.
- `RAWImageLoader` holds one base holder keyed by URL and RAW white-balance temperature/tint settings. Same-asset holder lookups can avoid another source decode; moving to a different asset replaces that holder. It is not a neighbor native decode cache.

## Verification boundary

The existing `InspectionTests` native method/state cases are the available no-GUI input repro. They are not a renderer/onChange integration repro and cannot establish GUI acceptance. Targeted `InspectionTests`: 23 passed. Full `swift test`: 70 passed, 3 opt-in benchmarks skipped. The `xcodebuild test` action is unavailable because the `LumiBase` scheme has no test action. A separate diagnostic-only Release build subsequently succeeded: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.4.6-ROI-Diagnostics.app`, version/build 1.4.6, bundle ID `com.lumibase.LumiBase.Inspection.ROI.Diagnostics`. All five copied files matched the fresh build product by SHA-256. This contains instrumentation, not a proven performance fix. Capture the debug events live with `/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "com.lumibase.inspection"'`; debug records may not be retained for later retrieval. Trace is capped at 600 events per process; restart the diagnostic app before a fresh reproduction. No GUI was launched and no original, sidecar, or preference files were written.
