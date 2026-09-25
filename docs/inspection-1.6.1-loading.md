# Inspection 1.6.1 — RAW thumbnail loading starvation

## Scope and dependency

This bugfix follows [Highlights 1.6.0 PR #3](https://github.com/tedyeng/LumiBase/pull/3), which depends on [PR #2](https://github.com/tedyeng/LumiBase/pull/2). It changes only thumbnail decode scheduling, the inspection version/build (1.6.1), and a regression test. Highlights kernel/service, pixel math, cache keys, ROI handoff, histogram, RAW preview, and export behavior are unchanged.

## Evidence and root cause

The original application sample showed the main thread in its normal event loop, many Swift cooperative workers blocked inside `ThumbnailLoader` → `CGImageSourceCreateThumbnailAtIndex` → RawCamera synchronous dispatch, and RawCamera provider workers waiting for dispatch groups. Highlights preparation/kernel was not on those blocked stacks.

A production-API regression test reproduces the workload using 16 real Canon CR3 files, 48 distinct cold application-cache thumbnail requests (180–227 pixels), and a foreground RAW decode plus processed preview queued after 0.2 seconds. The trigger uses a GCD timer rather than a Swift task timer; XCTest has a 45-second deadline and the process is additionally bounded externally.

- Before the fix: both thumbnail and preview expectations timed out at 45 seconds. The sampled cooperative workers were blocked in the same ImageIO/RawCamera path.
- After the fix: the same test passed in 23.246 seconds; three isolated repetitions passed in 22.895, 24.849, and 31.263 seconds. All 48 thumbnails and the foreground preview were non-nil.
- Foreground API/raster completion in those repetitions was approximately 785, 1030, and 1166 ms from initial enqueue, including the timer delay. These are not GUI frame-latency measurements.
- The original isolated Release suite ran 110 tests, with 6 skipped and 0 failures; the real-RAW test is opt-in and was exercised separately. The Release app build and strict ad-hoc signature verification passed. The user subsequently reported the delivered 1.6.1 app resolved the observed starvation.

Publication verification on the focused PR worktree reran the full Release suite with the optional calibrated DNG configured: **110 tests, 6 skipped, 0 failures**. Without that private fixture, the portable suite reports 12 skips rather than claiming that coverage. A separate fresh-home real-RAW run passed in **21.969 seconds**, with all **48 thumbnails / 16 CR3 sources** and the foreground preview completing; foreground API/raster completion was **794.7 ms**. The packaged `ThumbnailLoader.swift` is byte-identical to the source used for the user-tested 1.6.1 app (SHA256 `7896922eacb30373f76b0efdbeb1e247f7e2803bb4b8f198415eaa03c41fdb58`).

This differential reproduction supports cooperative-pool starvation from unbounded synchronous thumbnail decoding; it does not establish every private Apple decoder dependency or promise to fix all possible RAW decoder deadlocks. OS disk caches were not flushed.

## Narrow fix

`ThumbnailLoader` dispatches synchronous decoding to the private serial GCD queue `com.lumibase.thumbnail.decode` and suspends async callers with a checked continuation. Only one blocking thumbnail decode is active at a time. An autorelease pool releases temporary decode objects after each request. Existing shared in-flight deduplication and caching semantics remain intact.

## Portable reproduction

On macOS with Xcode installed, from this checkout, choose a scratch directory and a local read-only directory containing at least 16 CR3 files. No photographs are bundled or uploaded. The test selects the first 16 CR3 paths in sorted order.

```sh
export RUN_ROOT="${TMPDIR%/}/lumibase-loading-verification"
mkdir -p "$RUN_ROOT/tmp" "$RUN_ROOT/modules" "$RUN_ROOT/home-suite" "$RUN_ROOT/home-stress"
export TMPDIR="$RUN_ROOT/tmp"
export CLANG_MODULE_CACHE_PATH="$RUN_ROOT/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
CFFIXED_USER_HOME="$RUN_ROOT/home-suite" swift test -c release --disable-sandbox --scratch-path "$RUN_ROOT/build"
export LUMIBASE_LOADING_STRESS_FOLDER="/path/to/local/CR3-fixtures"
export CFFIXED_USER_HOME="$RUN_ROOT/home-stress"
python3 -c 'import os, subprocess; subprocess.run(["swift", "test", "-c", "release", "--disable-sandbox", "--scratch-path", os.environ["RUN_ROOT"] + "/build", "--skip-build", "--filter", "ImageLoadingConcurrencyTests"], check=True, timeout=75)'
```

Use a fresh scratch home for each stress repetition so the application disk cache cannot mask decoding. The test also gives requests a new modification timestamp. Inputs are read-only; cache output belongs in the isolated scratch home. Skipped tests must not be represented as passing fixture coverage.

## Limitations

- Active blocking decodes are bounded to one; the pending queue remains unbounded. Latest-request priority, queue-length limits, and obsolete-thumbnail cancellation are deliberately not added. Completing a gallery may still take tens of seconds.
- A single view cancellation does not cancel a shared in-flight thumbnail task. This change does not promise to interrupt Apple's synchronous decoder.
- Other synchronous RAW/histogram paths are not redesigned. Other workloads need their own samples and reproductions.
- Headless API verification is not a claim of automated GUI scrolling, selection, or folder-switching coverage. No GUI was launched during packaging, and no source photograph, sidecar, catalog, or preference was modified.
