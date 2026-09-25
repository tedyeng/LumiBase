# LumiBase 1.4.4 — bounded preview preload

## Behavior

- Preview speculation follows up to three assets before and after the current selection in `displayedAssets`, so the active sort and filters define the neighborhood. The next asset in travel direction is first, then the opposite neighbor, followed by increasing distance.
- A dedicated utility-priority worker performs preview-only ImageIO embedded-preview downsampling. At most one speculative job is active. Selection, list, folder, sort/filter, and develop changes replace the queue and invalidate stale completions. List snapshots are read after the published mutation has completed. Cancellation does not interrupt synchronous decoder work already in progress; it retains the sole worker slot until it returns.
- Speculative dispatch waits while the selected Loupe asset is loading/rendering. Only completion for that same selection releases the gate. Loupe disappearance cancels its queued speculation. A running synchronous decode cannot be preempted.
- Speculative bitmaps use an explicitly accounted LRU cache capped at 128 MiB. The coordinator reserves an in-flight bitmap allowance before dispatch and records materialized `bytesPerRow × height` when admitting a result. The cap applies only to speculative bitmap accounting; it is not a process-memory guarantee and does not include the visible frame, decoder, Core Image, GPU, or framework allocations.
- A cached preview is reused when its asset is selected. Its key includes canonical file identity, file modification time and size, the complete encoded XMP revision, output size, and pipeline identity.
- Under warning or critical memory pressure, the speculative queue and cache are purged and dispatch stays suspended until the normal pressure event. The latest eligible neighborhood may then be queued again. Teardown also clears speculative state.
- Develop-edited RAW assets are skipped. Other RAW assets are eligible only when ImageIO can provide an embedded thumbnail: full-image thumbnail fallback is disabled, and the asset is skipped if that thumbnail is absent. This iteration does not perform speculative full native RAW decoding or edited-RAW color processing. The ordinary foreground thumbnail, RAW, develop, and native-inspection paths remain in place.
- The preview remains a preview. It does not establish native 100% provenance. No originals, XMP sidecars, or preferences are written by speculative work.

## Preserved inspection behavior

The 1.4.3 temporary/persistent zoom, mouse release classification, held-wheel routing, sidebar behavior, native provenance, retained last valid frame, orientation, and render freshness paths were left in place. The preloader is not connected to `LiveDevelopPreviewEngine` or its coalesced foreground pending slot.

## Validation

- Final parent-run `swift test` passed 60 tests, including deferred published-state snapshots, memory pressure policy, RAW thumbnail options, foreground gating, an actor/ImageIO synthetic PNG fixture through the consumer cache API, and unchanged-selection/late-refresh foreground lifecycle regressions. Detailed output: `/Users/kitleong/projects/LumiBase-builds/preload-verified-tests.log`.
- Independent review identified a same-selection list-refresh permanent-pause defect; it was corrected with real AppState/preloader integration coverage. Initial feature RED was missing-type compilation; some later fixes were not observed assertion-RED due to worker sandbox failures. Do not claim complete strict TDD adherence.
- No preview-vs-native latency comparison or supported-camera RAW fixture measurement is claimed. The actor integration test uses generated PNG fixtures, not camera RAWs. The accounted cache budget excludes decoder/Core Image/GPU/framework allocations and does not bound total process memory.
- Final parent-run Xcode Debug build succeeded. All seven copied app files match the fresh build product by SHA-256.
- Build log: `/Users/kitleong/projects/LumiBase-builds/preload-verified-build.log`. Prior task run logs remain alongside the app artifact.
- No GUI acceptance, supported-camera fixture coverage, latency comparison, or performance improvement is claimed. Existing optional image fixtures are absent in this workspace.

## Artifacts

- Local app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.4.4.app` (rebuilt after fixes; not launched).
- Branch: `feature/bounded-inspection-preload`. No commit, push, PR, or adjacent PR branch change was made.
