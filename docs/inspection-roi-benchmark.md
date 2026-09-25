# Native full-frame vs visible-region render inspection

## Decision

The final four-source run supports a gated ROI prototype, not production rollout. Full-frame render/materialization median was 59.55 ms (60.95 ms including reference crop/copy), versus 9.05 ms for direct 2400×1600 ROI rendering, with 48 measured rows per condition. Strict pixel parity failed in all 24 cases: maximum channel difference 1, with 240,296 differing channel values out of 368,640,000. These are warmed API measurements under unrelated CPU load, not GUI latency or cold first-inspection timing. A 1-LSB tolerance would need explicit validation rather than declaring outputs identical.

## Method

The opt-in test is [ROIBenchmarkTests.swift](../Tests/LumiBaseTests/ROIBenchmarkTests.swift). It loads four read-only DxO PureRAW Linear DNGs from the existing `/Users/kitleong/projects/LumiBase-builds/dxo-benchmark/sample-manifest.json`, spanning 4026×3018, 6240×4162, 6469×4160, and 9504×6336. The sources are DJI FC3582 and Sony ILCE-7RM5. Actual manifest metadata, native extents, and CIRAWFilter temperature/tint baselines are recorded in `roi-benchmark-output/raw-results.json`.

Each source was decoded once with the native `CIRAWFilter` settings copied from [RAWImageLoader.swift](../LumiBase/Services/Image/RAWImageLoader.swift#L88): exposure 0, baseline exposure 0.30, zero shadow bias and shadow boost, boost 1, and highlight recovery on macOS 26 or newer. The same full processed graph from [AdobeColorPipeline.swift](../LumiBase/Services/Image/AdobeColorPipeline.swift) was given either the full native extent or a visible source rectangle. The graph input was never cropped. Both paths shared one warmed `CIContext` with production loader options (`useSoftwareRenderer=false`, `highQualityDownsample=true`) and rendered RGBA8 sRGB with `deferred:false`.

ROIs were center, top-edge midpoint, and all four corners. Each requested 2400×1600 native pixels, clipped to the image and aligned to integer source coordinates. Each ROI received one unrecorded full and ROI warm-up, then two matched renders per condition in full/ROI/ROI/full order. ROI traversal direction alternated between source files. The render timer included pixel materialization and row packing; checksums were calculated after the timer stopped. Decode and graph construction were timed once per source. Full-frame output was released between ROI cases. Crop/copy was timed separately. The raw record count is 96/96 expected renders; there are 24/24 parity cases. Summary JSON includes aggregate and per-source/per-ROI medians, p95 values, and counts.

The uniform develop settings were explicit **synthetic in-memory experiment settings**, not values read from DNG metadata: Exposure +0.35 EV, Temperature 6100, Tint +8, Contrast +12, Highlights -18, Shadows +22, Whites +8, Blacks -5, Vibrance +14, Clarity +8, Texture +4. The manifest identifies embedded develop metadata in DJI_0653, DSC07818, and DSC07821; those values were recorded as provenance but were not fed to this render. The selected DSC09202 has no embedded develop edits according to the manifest. The manifest and prior DxO inspection report no external XMP sidecars for these samples.

## Results

| Measurement | Full native render + crop reference | Direct visible-region render |
| --- | ---: | ---: |
| Forced render and materialization, median (n=48) | 59.55 ms | 9.05 ms |
| Forced render and materialization, p95 (n=48) | 191.33 ms | 10.15 ms |
| Total including reference crop/copy, median | 60.95 ms | 9.05 ms |
| Total including reference crop/copy, p95 | 194.95 ms | 10.15 ms |

The separate full-output crop/copy measurement was 1.47 ms median and 2.00 ms p95 (n=24). Decode plus graph construction was 105.30 ms for DSC09202, 19.23 ms for DJI_0653, 18.64 ms for DSC07818, and 18.30 ms for DSC07821. The slower first result reflects this single run and is not a cold-cache claim. CIRAWFilter WB was set to match production: the synthetic 6100/+8 values were applied to native temperature/tint with the production temperature compensation, then the identical settings were passed to AdobeColorPipeline with matching holder baselines.

All 24 ROI/crop pairs had the expected 2400×1600 dimensions. Using the CGImage top-origin crop mapping, all had a maximum channel difference of 1; 0/24 were exactly equal. Across the 24 outputs, 240,296 channel values differed out of 368,640,000 (0.0652%). The largest individual case had 26,361 differing channel values. The alternate vertical mapping was included diagnostically and produced large mismatches, confirming the top-origin mapping used for the reported comparison. The harness asserts exact equality, so its opt-in test **fails on the expected strict parity assertion**. That failure is retained as evidence; the outputs are not marked equivalent.

Process checks around the run block found no concurrent benchmark worker, but did find heavy unrelated load: a persistent Python metadata-manager process at about 87% CPU, followed by XProtect Remediator at about 96% CPU and Logitech background processes. This can distort timings, especially the full-render p95, so treat the measurements as noisy. The run used explicit warm-ups and makes no cold OS-cache claim. `/usr/bin/time -l` condition-isolated memory was unavailable; process memory was not inferred from pixel dimensions. No GUI latency or production speedup is claimed.

## Source integrity and artifacts

Only the four selected manifest DNGs were read. Before/after SHA-256 matched for all four; the harness found no listed sidecars. No source or sidecar was written. The raw JSON also contains each input hash, actual manifest metadata, settings, extents, outputs, checksums, and per-case diffs.

- [Raw render rows (CSV)](roi-benchmark-output/raw-results.csv)
- [Raw render, parity, metadata, and hashes (JSON)](roi-benchmark-output/raw-results.json)
- [Generated aggregate summary (JSON)](roi-benchmark-output/summary.json)
- [Per-case pixel parity (CSV)](roi-benchmark-output/parity.csv)

Reproduction command for the final four-source sample:

```sh
LUMIBASE_ROI_BENCHMARK=1 \
LUMIBASE_ROI_MANIFEST=/Users/kitleong/projects/LumiBase-builds/dxo-benchmark/sample-manifest.json \
LUMIBASE_ROI_OUTPUT=/Users/kitleong/Projects/LumiBase/docs/roi-benchmark-output \
LUMIBASE_ROI_PATHS='/Volumes/Extreme SSD/Working/2026.05.23-25 Memphis/DXO/DJI_0653-DXO6.dng|/Volumes/Extreme SSD/Working/2026.03.07-08 Dallas/DXO/DSC07818-DXO6.dng|/Volumes/Extreme SSD/Working/2026.05.23-25 Memphis/DXO/DSC09202-DXO6.dng|/Volumes/Extreme SSD/Working/2026.03.07-08 Dallas/DXO/DSC07821-DXO6.dng' \
swift test --scratch-path /Users/kitleong/.hermes/cache/scratch/LumiBase-ROIBenchmarkBuild \
  --filter ROIBenchmarkTests/testNativeFullVersusVisibleRegionBenchmark
```

## Code-evidenced duplicate-work audit

This is a static call-path audit. The benchmark did not instrument decoder entry counts or production callers, so the items below are **possible repeated work**, not measured duplicate decoder invocations.

1. **Base RAW decode has no in-flight sharing.** [RAWImageLoader.swift](../LumiBase/Services/Image/RAWImageLoader.swift#L44) keeps a single completed holder. A caller checks it at lines 50–54, then starts a detached decode at lines 72–78; publication happens later at lines 198–203. The lock protects lookup and publication separately, so two concurrent misses for the same URL and white-balance settings can both create `CIRAWFilter` and decode the same RAW. The key itself only includes temperature and tint ([lines 4–13](../LumiBase/Services/Image/RAWImageLoader.swift#L4)).
2. **Selection intentionally overlaps a thumbnail and native decode.** [LoupeView.swift](../LumiBase/Views/Center/LoupeView.swift#L622) starts thumbnail preparation and then awaits `loadBaseHolder` at line 639. On a preloader miss, the thumbnail request falls through to [ThumbnailLoader.swift](../LumiBase/Services/Image/ThumbnailLoader.swift#L69), which decodes an ImageIO preview while RAWImageLoader performs its native RAW decode. These are distinct outputs and the overlap helps paint early, but it can duplicate source-file work. The preview preloader has one worker and cancels publication on selection, yet cancellation is checked after its ImageIO decode ([PreviewPreloader.swift](../LumiBase/Services/Image/PreviewPreloader.swift#L283)); an already-running decode can finish while foreground work proceeds.
3. **Thumbnail coalescing is local and key-sensitive.** [ThumbnailLoader.swift](../LumiBase/Services/Image/ThumbnailLoader.swift#L23) shares a task only for the same thumbnail key. The key contains size and only exposure, temperature, and highlights ([lines 14–16](../LumiBase/Services/Image/ThumbnailLoader.swift#L14)), so requests with different omitted develop settings do not get distinct work keys. The thumbnail actor does not share work with RAWImageLoader or PreviewPreloader. This is a code risk, not evidence of a duplicate decode in the measured run.
4. **Fit mode renders an interactive result and an idle refinement.** [LoupeView.swift](../LumiBase/Views/Center/LoupeView.swift#L675) submits an interactive render immediately, then schedules a non-interactive render after 200 ms at lines 684–697. [LiveDevelopPreviewEngine.swift](../LumiBase/Services/Image/LiveDevelopPreviewEngine.swift#L43) replaces pending requests with the latest request, but cannot stop one already being rendered. The two outputs have different proxy sizes, so this is intentional staged work; rapid revisions can still leave an obsolete active render plus the latest pending render.
5. **Other views reuse the base cache but rasterize independently.** [HistogramView.swift](../LumiBase/Views/Inspector/HistogramView.swift#L106) requests the same base holder and separately renders its interactive image before computing a histogram. A live preview can be processing the same holder concurrently. This is a candidate for render sharing or instrumentation, not a measured duplicate.

The one-time completed-holder cache and the thumbnail memory/disk cache should reduce later repeated calls. [ThumbnailCacheManager.swift](../LumiBase/Services/Image/ThumbnailCacheManager.swift#L33) stores thumbnails by URL, modification time, size, and develop tag. `ThumbnailLoader` shares same-key in-flight tasks; `LiveDevelopPreviewEngine` coalesces pending frames; `PreviewPreloader` permits one speculative decode at a time and suppresses stale publication. These protections apply within their own paths, not across RAW holder decode, thumbnail decode, preview speculation, and processed rendering.

### Verification

The normal Swift suite passed: 63 tests, 0 failures, 3 opt-in benchmark tests skipped (context, SSD, and ROI). The final focused ROI run completed all 96 measured renders and 24 parity comparisons in 73.4 seconds and failed only the strict parity assertion (0/24 exact). The failed opt-in status is intentional evidence that outputs were not declared equivalent.
