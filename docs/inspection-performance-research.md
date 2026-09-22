# Inspection performance: bounded prefetch proposal

Status: research only; NOT implemented in 1.4.3. No promised speedup without measurement.

## Findings from the current code

- `RAWImageLoader` reuses one CIContext and caches one base holder keyed by URL and decode white balance. Returning A → B → A therefore misses the one-holder cache.
- `LiveDevelopPreviewEngine` coalesces pending renders. Speculative renders must NOT use its single pending foreground slot: they could replace the current user's request.
- Loupe preserves the last valid frame, overlaps thumbnail/native loading, and avoids rerendering an already-valid native frame on release/reentry. Preserve these invariants.
- `ThumbnailLoader` deduplicates identical in-flight thumbnail requests, but creates a fresh CIContext in its edited-RAW path. Reusing a context is a concrete candidate worth benchmarking; Apple recommends context reuse because contexts retain substantial state.[1]
- Thumbnail work uses detached user-initiated tasks. A new prefetch coordinator must explicitly own cancellation, concurrency and priority rather than launching many calls to the existing loader.

## Recommended experiment

Interpret “前後 3–5 張” as a configurable maximum radius, not an obligation to keep all full-resolution images resident.

1. Start with preview radius ±3; allow ±5 only inside the same byte budget. Prioritize next image in travel direction, previous image, then increasing distance. Use the current sorted/filtered asset list, not filesystem order.
2. Keep full/native data for the current image and optionally one predicted next image only when there is budget. Do not decode all 6–10 neighbors at native resolution.
3. Prototype a **128 MiB speculative preview budget**, separate from the current visible frame, with at most one speculative decode/render in flight. This number is an initial experiment parameter, not a measured safe process-memory ceiling.
4. Use explicitly accounted LRU eviction plus admission checks. NSCache's totalCostLimit is not a strict limit and eviction order is unspecified; it cannot alone guarantee a hard budget.[2]
5. Count materialized bitmap bytes (`bytesPerRow × height`) and reserve estimated in-flight cost before dispatch. Track decoder/GPU/CI allocations separately via resident/physical footprint measurement: CIImage graphs and shared backing cannot be accurately costed simply by adding logical dimensions.
6. Cancel/reprioritize on selection, direction, folder, sort/filter and develop changes. Under memory pressure, clear speculative entries and stop speculation. Eviction must not invalidate the currently displayed frame.
7. Cache keys must include asset identity/file modification, decode WB, full relevant develop revision, orientation, output dimensions/quality and color-space/pipeline version as appropriate. Do not copy the existing thumbnail key's partial develop tag into a new full-render cache.
8. Coalesce same-key work and promote an in-flight speculative request when it becomes selected. Foreground rendering always wins. Cancellation stops queued work but must not be presented as guaranteed interruption of in-flight GPU work.
9. Preserve native provenance: an embedded preview is never native 100%; loading/unsupported errors remain truthful. No source/sidecar writes.

## Why a count limit alone is unsafe

Calculated illustrative uncompressed buffer costs (not observed process memory):

- 24 MP RGBA8: 91.6 MiB per buffer; RGBA half-float: 183.1 MiB.
- 60 MP RGBA8: 228.9 MiB; RGBA half-float: 457.8 MiB.
- Actual residency includes the visible image, decoding, intermediate surfaces, proxies and framework overhead, so these are only per-buffer illustrations.

Thus “five photos” can mean very different memory costs. Use both radius and byte admission limits. Apple also recommends smaller output images when appropriate and Image I/O downsampling, and warns against unnecessary CPU/GPU texture transfers.[1] Do not trade color correctness for speed by disabling color management in this photo application.

## Measurement and acceptance before implementation ships

Compare prefetch off, ±3 preview, and ±5 preview under identical sequences: sequential forward/back, direction reversal, A/B oscillation, random jumps, held-wheel navigation and develop edits. Use synthetic raster fixtures plus explicitly provided supported/unsupported camera RAWs; missing RAW fixtures are not camera coverage.

Record p50/p95 input-to-first-valid-preview and input-to-native-frame latency, decode and render durations separately, cache hits/misses, cancelled/wasted work, peak physical footprint, memory-pressure recovery, and foreground stalls. CIImage/NSImage construction timing alone is insufficient; force raster completion and separately measure actual presentation when GUI access is available.

Regression tests must cover stale completion rejection, cancelled jobs not publishing, foreground priority, one-job concurrency, byte-budget admission/eviction, pressure purge, sort/filter invalidation, WB/develop keys, unsupported RAW, and temporary/persistent mouse release behavior. Start with CIContext reuse and preview-only prefetch; consider a Metal-backed presentation path only if profiling demonstrates a material transfer/presentation bottleneck.

## Sources

[1] https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html
[2] https://developer.apple.com/documentation/foundation/nscache/totalcostlimit
