# SSD inspection benchmark

> **Review correction:** The initial ON/OFF comparison was invalid for speedup conclusions. OFF used varying output sizes while ON used 1600px, and its random traversal was mistakenly supplied as the gallery order, so every next target was adjacent. The first run's raw files and measurements are preserved unchanged in `/Users/kitleong/projects/LumiBase-builds/ssd-benchmark/`; do not cite its 102/102 hits as random-navigation accuracy. Corrected results below are a separate, explicitly warm foreground-cache measurement.

## Scope and method

The opt-in XCTest harness is [SSDBenchmarkTests.swift](../Tests/LumiBaseTests/SSDBenchmarkTests.swift). Ordinary `swift test` skips it unless `LUMIBASE_SSD_BENCHMARK=1` and manifest/output environment variables are set. The run uses the production `RAWImageLoader`, `PreviewPreloader`, and `ThumbnailLoader` APIs against 18 originals in `/Volumes/Extreme SSD/Working`; no copies were used, so the test retains original volume reads. This is not a claim of cold SSD performance.

The manifest contains nine paired JPEG and Olympus ORF files from `2025.03.01 Martin Park, NH Jam`. JPEG source dimensions are 5184 × 3888; ORF source metadata reports 5220 × 3912. Dotfiles and AppleDouble files were excluded. The sample had no matching XMP sidecars. Nine RAW files had no parsed develop edits; zero edited RAW files were excluded, and all 18 files were eligible for preload navigation.

The corrected trials hold the gallery in manifest order and pass independent sequential, reversed, or seeded-random navigation indices. The seeded order has 16 non-neighbor transitions among its 17 moves. Direction starts stationary and is updated from each completed move's actual gallery-index delta; no future target determines the direction. Both arms request a 1600px maximum output. Assertions check the preview size constant, per-trial 1600px request, constant gallery order, random permutation, and presence of non-neighbor random targets.

Before timing, the harness calls the foreground thumbnail API for every eligible original at 1600px to explicitly prime its existing memory/disk cache. It does not clear or remove the global app cache. In the delivered invocation, this priming took 6.45 ms with zero failures; an immediately preceding corrected invocation had already populated these same cache keys. This is therefore an explicitly warm foreground-cache arm with normal OS cache state, not a cold-cache or cold-storage comparison. The user cache may contain the thumbnails primed by the benchmark.

Each navigation transition has a 150 ms dwell. ON records preloader update-call cost and time until a speculative preview is ready during dwell; retrieval timing is after dwell. ON misses and every OFF read use the foreground thumbnail API. Values below aggregate 34 retrievals per condition (17 moves × 2 repeats); preparation and ready times aggregate the 34 ON moves. The benchmark also measures base `CIImage` holder construction and a forced full-resolution raster pass once per file. The isolated benchmark test passed in 40.25 seconds; `/usr/bin/time -l` reports 41.85 seconds wall and maximum RSS 508,379,136 bytes (about 0.47 GiB) for the invocation.

## Corrected measurements

Times are milliseconds. Update = preloader `update` call; ready = time from update start until preview availability or the end of the dwell polling. Async cache checks can finish after the nominal 150 ms dwell, so observed ready p95 may exceed 150 ms.

| Sequence | Mode | Retrieval median / p95 | Update median / p95 | Ready median / p95 | Hits / misses / failures |
|---|---|---:|---:|---:|---:|
| Sequential | OFF | 0.22 / 0.34 | — | — | 0 / 34 / 0 |
| Sequential | ON | 0.25 / 0.46 | 1.16 / 2.06 | 1.27 / 75.23 | 34 / 0 / 0 |
| Reversal | OFF | 0.21 / 0.32 | — | — | 0 / 34 / 0 |
| Reversal | ON | 0.27 / 0.53 | 1.26 / 2.41 | 1.41 / 65.61 | 34 / 0 / 0 |
| Seeded random | OFF | 0.23 / 0.30 | — | — | 0 / 34 / 0 |
| Seeded random | ON | 0.15 / 0.43 | 0.58 / 2.32 | 1.50 / 178.79 | 24 / 10 / 0 |

Across all 18 files, base `CIImage` holder construction had a 47.42 ms median and 153.31 ms p95. Forced native raster completion had a 52.72 ms median and 260.43 ms p95. All 18 holder constructions and all 18 forced renders succeeded; Core Image reported raster dimensions of 5184 × 3888 for both file types. There were no foreground thumbnail failures. The random ON arm missed 10 times and used foreground thumbnail fallback on those moves.

These timings compare a speculative preview lookup with a foreground thumbnail lookup after both use the explicitly warmed foreground cache conditions described above. They do not establish app-level navigation speedup, cold-storage performance, or a per-arm memory cost. Cache hits, image decoding, scheduling, and UI presentation differ from this harness timing model.

## Provenance and artifacts

The before fingerprints in the manifest were checked against all 18 original files after the corrected run. SHA-256, size, and modification time all matched; zero source paths changed. No source image or sidecar was written. No upload or app GUI launch occurred. The benchmark did intentionally populate/look up foreground thumbnail cache entries and did not clear the user global cache.

Corrected artifacts are in `/Users/kitleong/projects/LumiBase-builds/ssd-benchmark-corrected/`:

- `sample-manifest.json` — original paths, source fingerprints, dimensions, and sidecar inventory
- `raw-results.json` — per-image decode/render and per-transition timing arrays, indices, cache state, hits, misses, and failures
- `summary.json` — medians, p95s, exclusions, random non-neighbor count, and cache-priming cost
- `process-time.txt` — `/usr/bin/time -l` output
- `source-fingerprints-after.json` and `preservation-check.json` — post-run fingerprints and comparison
- `original-raw-preservation.json` — hashes for the unchanged first-run artifacts

The first run's invalid comparison values remain documented for provenance only. It reported sequential OFF/ON retrieval medians of 225.60/0.18 ms, reversal 103.17/0.27 ms, and seeded-random 448.30/0.14 ms. Its corresponding p95s were 271.83/0.45, 485.61/0.50, and 499.20/0.44 ms; preview-ready medians/p95s were 0.78/59.53, 1.28/42.42, and 0.48/57.59 ms. Base `CIImage` construction measured 46.99 ms median / 2675.96 ms p95, and forced raster completion 95.56 / 357.04 ms. The old test completed in 66.25 seconds; the timed invocation took 67.60 seconds and reported maximum RSS 2,454,536,192 bytes (about 2.29 GiB). Its mismatched pixel sizes and false random-neighbor model make those results unsuitable for performance claims. Its original raw results and process record remain at `/Users/kitleong/projects/LumiBase-builds/ssd-benchmark/`.

## Limits

The sample is small and contains one camera's RAW files. API timings omit app launch, UI scheduling, display presentation, and input-to-screen latency. The explicit foreground-cache priming controls availability of 1600px thumbnails but does not reproduce a fully cold or uniformly warm operating-system cache. Results are one run and should be treated as measurements of these loader APIs under the recorded warm-cache state.
