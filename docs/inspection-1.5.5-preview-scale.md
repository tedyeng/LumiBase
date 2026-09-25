# LumiBase 1.5.5 preview geometry and folder-switch review

## Preview geometry correction

The warmed-preview handoff carried the preview bitmap dimensions as the image's `fullExtent`. At held 100%, the no-ROI layout used the bitmap's own pixel size, so a 1600 px preview was drawn as if those 1600 pixels were the complete source. The entire picture therefore appeared to shrink while native rendering was pending; this path was not CR3-specific.

The ImageIO preview worker now records the source's oriented pixel extent separately from the decoded proxy bitmap. Loupe's ready-frame handoff carries that full extent into layout. A pending preview uses the original extent to set 100% scale and center while its bitmap is stretched across the same native viewport positions. When the native frame arrives, its original extent yields the same scale and position. Fit continues to use the displayed bitmap. If ImageIO cannot establish the source extent, the pending preview stays fit-sized and the layout does not pretend its proxy dimensions are native geometry.

When a cached processed ROI is shown before the base holder is warm, the decoded holder's full extent is now checked against the cached ROI extent. A mismatch restores the valid full-frame preview and requests a current native render. Matching geometry retains the existing warm handoff.

## Regression evidence

The held-selection test was added and run before the behavior changes. It failed at the production ready-frame producer → selection handoff → frame layout seam with three assertions: the proxy had an 800×400 point layout instead of the 4096×2048 point layout for an 8192×4096 source at backing 2; the handoff stored 1600×800 as the full extent; and native completion changed the apparent scale. The final regression sends both 400×200 and 1600×800 synthetic proxies through `PreviewPreloader`'s real scheduler, worker completion, and ready-frame publication before selection. It checks held 100% scale and center placement, Fit sizing, then native repress scale and center position. Only the decoder is injected to supply controlled synthetic pixels and source dimensions.

Additional checks cover unknown source dimensions, the real preview worker publication, mismatched cached ROI versus holder extent, and a matching portrait extent with nonzero origin. The existing ROI source-rectangle coverage exercises backing scales 1 and 2 and portrait/nonzero-origin requests.

## Folder-switch review and limits

The 1.5.4 folder-switch changes remain in this candidate. The review inspected `AppState.openFolder` / refresh cancellation and generation checks, `FolderScanner` cancellation and bounded decode scheduling, security-scope lifetime, and `DirectoryWatcher` stop/callback behavior. Queued watcher events can request a refresh of the current folder; generation and folder checks prevent an older scan from publishing stale assets. No concrete introduced blocker was found in those paths.

The sidebar still synchronously lists subfolders when a collapsed row is expanded. That path was not changed or measured. The supplied post-restart sample is idle in AppKit's event wait and does not overlap a confirmed hang, so neither the folder fixes nor this review proves the original force-quit symptom is resolved. Thumbnail decode calls may also outlive canceled view tasks; their contribution remains unmeasured.

The candidate was not launched. No GUI navigation, user photos, sidecars, preferences, or catalog were used. No commit or push was made. Existing dirty work was preserved.

## Candidate verification

The complete Swift suite passed with **96 tests, 3 opt-in benchmarks skipped, and 0 failures**. The Release Xcode build succeeded. The durable app is `LumiBase-Inspection-1.5.5-ROI.app`, version/build `1.5.5`, bundle ID `com.lumibase.LumiBase.Inspection.ROI`. The executable SHA-256 and full app-file manifest are recorded in `/Users/kitleong/.hermes/cache/scratch/lumibase-1.5.5-roi/bundle-files.sha256`; full test and Xcode logs are in the same scratch directory.
