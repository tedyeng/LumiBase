# CIContext lifetime benchmark

> Measurement review: `thumbnail_pipeline_ms` includes reading pixel data and computing SHA-256 for output verification, not solely production thumbnail latency. The metric named `forced_cgimage_raster_ms` stops at createCGImage return, before dataProvider bytes are read; it does not independently prove the exact time all pixel work completed. Treat the end-to-end-with-verification comparison as exploratory. A follow-up should stop its render timer after forced pixel materialization and before checksum computation. Per-condition resident memory was not measured.

## Result

The opt-in benchmark ran after the SSD and DxO workers (PIDs 88480 and 89409) had exited. It passed with 32 measured renders across four files and two output sizes. Sixteen renders used a fresh context and sixteen reused the same context. All repeated CGImage byte checksums and output dimensions matched for each input/size pair; all four image hashes matched before and after. No XMP sidecars were present.

| Metric | Fresh context each render | One reused context |
| --- | ---: | ---: |
| Context construction, median / p95 (ms, n=16) | 0.478 / 5.124 | 0 / 0 per render |
| Forced CGImage raster, median / p95 (ms, n=16) | 86.206 / 277.601 | 77.839 / 257.093 |
| Total thumbnail pipeline, median / p95 (ms, n=16) | 114.199 / 346.426 | 103.644 / 318.057 |

The reused context was constructed once in 11.091 ms before warm-up; that one-time setup is reported separately and is not included in each reused render's pipeline time. The reused condition's median total pipeline time was 9.2% lower in this sample. This is a small, hardware-specific API benchmark, not evidence of GUI or user-perceived speedup. The high p95 values and small sample make tail comparisons noisy.

## Question and scope

Compare the edited RAW thumbnail path with a new `CIContext` for every thumbnail render against a single reused `CIContext`. This experiment does not change production code and does not measure GUI or input-to-screen latency.

The benchmark's render path follows `ThumbnailLoader.createThumbnail`: open each RAW with `CIRAWFilter`, apply `AdobeColorPipeline.shared.process`, scale the resulting `CIImage` to the requested maximum dimension, call `CIContext.createCGImage`, then create an `NSImage`. Both conditions use `.useSoftwareRenderer: false` and otherwise identical options, input images, settings, and output sizes (1600 and 400 pixels).

## Samples and develop settings

The bounded manifest selects two ORF camera RAWs from `/Volumes/Extreme SSD/Working/2025.03.01 Martin Park, NH Jam` and their corresponding DxO DNG files from its `DxO` subfolder. Existing XMP sidecars were checked and none were present. The test therefore applies these explicit synthetic values in memory, without changing any image or sidecar: Exposure +0.35 EV, Temperature 6100, Tint +8, Contrast +12, Highlights -18, Shadows +22, Whites +8, Blacks -5, Vibrance +14, Clarity +8, Texture +4.

## Method

The opt-in test is `Tests/LumiBaseTests/ContextBenchmarkTests.swift`. It performs one warm-up render per image/output-size pair per condition, then four matched measurements in fresh/reuse/reuse/fresh order for each pair. Each render uses its own `autoreleasepool`. Timings separately capture context construction, forced `createCGImage` raster completion, and total thumbnail pipeline time. Output dimensions and SHA-256 checksums of the rendered CGImage byte buffers are compared across repeated renders. SHA-256 hashes of each input image and any listed sidecar are recorded before and after.

Input files were read only. All four before/after source hashes matched, and there were no sidecars to hash. Timings do not claim a cold OS file cache; sample order, OS cache, CI caches, and hardware scheduling can affect results. Memory is unavailable because the matched ABBA conditions ran in one XCTest process and no condition-isolated `/usr/bin/time -l` RSS was collected.

## Running

Run the opt-in test with a separate Swift scratch directory:

```sh
LUMIBASE_CONTEXT_BENCHMARK=1 \
LUMIBASE_CONTEXT_MANIFEST=/Users/kitleong/projects/LumiBase-builds/context-benchmark/sample-manifest.json \
LUMIBASE_CONTEXT_OUTPUT=/Users/kitleong/projects/LumiBase-builds/context-benchmark \
swift test --scratch-path /Users/kitleong/projects/LumiBase-builds/context-benchmark/swift-build --filter ContextBenchmarkTests/testContextLifetimeBenchmark
```

The measured run passed with one test and zero failures. Raw trial rows are emitted as JSON and CSV; a program-generated JSON summary reports median, p95, and counts. The manifest, raw results, summary, and isolated build products are in `/Users/kitleong/projects/LumiBase-builds/context-benchmark/`.
