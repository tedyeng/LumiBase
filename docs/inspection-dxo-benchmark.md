# DxO PureRAW DNG benchmark

> Review caveat: Preview ON/OFF timing is exploratory only, NOT a valid acceleration comparison. The inherited harness changes foreground output sizes and uses the traversal as the gallery order (so its random case is not genuine random jumps against a fixed gallery). Also the injected embedded-edit flags make the workload differ from the unmodified app's metadata behavior. Native construction/raster observations below remain measurements of this harness workload, not GUI latency or stock-app throughput.

Run on 2026-09-22 against 12 DNGs in two `Working/*/DxO` folders, using an isolated copy of the opt-in SSD benchmark and the production LumiBase image APIs. The sample was six files from `2026.05.23-25 Memphis/DXO` and six from `2026.03.07-08 Dallas/DXO`.

## Sample provenance

ExifTool identified all 12 as DNG 1.7, `PhotometricInterpretation=Linear Raw`, and `Software=DxO PureRAW 6`. The files retain their original source camera filenames. The sample includes DJI FC3582 files at 4026×3018 and Sony ILCE-7RM5 files from 6240×4162 through 9512×6336. These are DxO-processed linear DNGs, not untouched camera-raw originals. The input list and metadata are in `sample-manifest.json` in the output directory.

There were no external XMP sidecars beside the selected files. ExifTool found embedded Lightroom develop values in 8 DNGs; the remaining 4 were preload eligible. LumiBase's current `MetadataReader` does not import embedded develop values (it only imports an embedded rating), so the isolated harness supplied a nonzero `XMPMetadata.exposure2012` for those 8 based on read-only ExifTool inspection. This let the production `PreviewPreloader.isSafeToSpeculate` and `ThumbnailLoader` exercise their existing edited-RAW exclusion behavior. The exclusion count is therefore based on the embedded metadata inspection, not on LumiBase discovering those embedded edits itself.

## Measurements

| Measurement | Result |
| --- | ---: |
| Files / edited RAW exclusions / preload eligible | 12 / 8 / 4 |
| Base holder / CIImage construction, median / p95 | 28.86 / 36.61 ms |
| Forced full-resolution native raster completion, median / p95 | 598.24 / 1,421.59 ms |
| Native holder and forced raster successes | 12 / 12 each |
| Preview dwell; sequence order | 150 ms; sequential, reversal, seeded random (73421) |
| Preload OFF foreground reads | 18 misses, 0 failures; median / p95 171.46 / 249.62 ms |
| Preload ON reads | 3 hits, 15 misses, 0 failures (16.7% hit rate); median / p95 155.20 / 225.42 ms |
| Preloader update scheduling time | median / p95 0.409 / 0.731 ms |
| Preview readiness observed during dwell | median / p95 153.17 / 167.92 ms |

The readiness value is when polling observed a cached preview, or the polling loop's end when none was ready within the dwell. It is not a decode duration for every item. Only 3 of 18 ON reads had a completed preview by retrieval; 15 used the regular foreground thumbnail API. Sequential had 1 hit in 6 reads, reversal 2 in 6, and random 0 in 6. All native decode, raster, and foreground thumbnail calls completed without failure.

The test used the production `RAWImageLoader.loadBaseHolder`, `RAWImageLoader.renderProcessed`, `PreviewPreloader`, and `ThumbnailLoader` APIs. Base-holder timing is API completion, not a claim that all source pixels were rasterized. Full raster timing explicitly forced processed-image completion at native output dimensions. Foreground thumbnail target sizes varied between repeated trials (1177 px plus a trial/sequence offset) to avoid reusing the benchmark's own thumbnail-cache keys; the speculative preview remains 1600 px. The ON/OFF retrieval medians are descriptive and should not be read as a clean speedup comparison because misses call the foreground loader and the output sizes differ.

## Integrity and limits

SHA-256 and byte-size checks were recorded before and after for all 12 sampled DNGs. Every sampled file matched; there were no sidecars to hash. The benchmark issued no writes to the external SSD. Results are not GUI frame latency, and the run did not control the OS disk cache or establish cold-disk performance. It also does not establish embedded develop-edit detection in the app's current metadata reader.

Raw measurements, summary, CSV exports, sample metadata, and hash verification are in `/Users/kitleong/projects/LumiBase-builds/dxo-benchmark/`. The separate Swift scratch build used `/Users/kitleong/.hermes/cache/scratch/LumiBase-DxOBenchmarkBuild`. The temporary harness copy and its derived build were kept outside the repository; the shared benchmark test and its owner's documentation were not edited.
