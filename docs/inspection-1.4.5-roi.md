# LumiBase inspection 1.4.5 ROI prototype

## Scope and use

This experimental build adds an explicit `ROI OFF · EXP` / `ROI ON · EXP` control to the loupe. It starts OFF and is held only in view memory; it does not write preferences. When enabled in native 100% zoom, LumiBase renders the visible source window plus a bounded 256 native-pixel margin on every side. The rectangle is calculated from the normalized inspection center, viewport size, and backing scale, then clamped to the oriented image extent, including nonzero Core Image origins. The app renders the existing full processed Core Image graph and asks the context to materialize only that rectangle; it does not crop the raw input or enlarge a proxy. Fit and export keep their existing paths.

Pan requests are delayed by 25 ms and routed through the existing latest-pending render engine, which replaces queued requests. Selection, develop, and zoom revisions reject stale completion. Each accepted frame retains its full source extent as well as an optional ROI rectangle. Layout derives ROI placement and clamp size from that frame provenance, so clearing the current holder while a new selection loads cannot recenter the staged crop using the new selection's dimensions. A native ROI is not reusable when zoom ends; Fit immediately restores the last valid full frame while its preview refreshes. Disabling ROI also restores that full frame immediately. Unsupported native input also uses the existing full-resolution eligibility path, and a failed ROI render retries full native once.

## Verification

- ROI transition RED log: `LumiBase-builds/roi-blockers-red.log` — with the prior native-frame reuse and no-op restore behavior, the new Fit/release and ROI-disable tests failed 11 assertions (reproduced against the prior behavior).
- Full suite GREEN log: `LumiBase-builds/roi-blockers-green.log` — 70 tests, 0 failures, 3 opt-in benchmarks skipped. New production-helper tests cover ROI-to-Fit sizing, persistent toggle-off, immediate ROI toggle-off restore, and pending selection with a nonzero old extent and different pending-source dimensions.
- Native synthetic graph smoke: `testFullResolutionRenderDoesNotUseProxy` renders a 120×12 regional output from a 3000×20 full source through the production color graph and asserts the output geometry.
- Existing inspection tests cover held press/release, double-click, pan, wheel navigation, selection changes, and stale display tickets.
- Release build: `LumiBase-builds/roi-blockers-xcodebuild.log` — `xcodebuild -project LumiBase.xcodeproj -scheme LumiBase -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO MARKETING_VERSION=1.4.5 CURRENT_PROJECT_VERSION=1.4.5 PRODUCT_BUNDLE_IDENTIFIER=com.lumibase.LumiBase.Inspection.ROI build` succeeded. All 5 app bundle entries match the build product's SHA-256 hashes; the installed bundle reports version/build 1.4.5 and ID `com.lumibase.LumiBase.Inspection.ROI`.

No GUI was launched, so visual frame placement and interaction feel have not been visually confirmed. The tests assert production layout and state transitions. This build is unsigned (`CODE_SIGNING_ALLOWED=NO`). No original photos, sidecars, or preferences were written. The bundled version is 1.4.5 with inspection-only bundle identifier `com.lumibase.LumiBase.Inspection.ROI`; previous 1.4.3 and 1.4.4 artifacts were left intact.

## Benchmark limitation

The preceding four-source benchmark remains unchanged. Strict parity failed in all 24 pairs: maximum channel difference was 1 LSB, and 0/24 outputs were exactly equal. Those results used synthetic in-memory settings and warmed API timings under unrelated CPU load. They do not establish exact equality, general image parity, cold latency, or GUI performance. This prototype makes no performance claim.
