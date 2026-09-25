# Inspection 1.5.2: warm selection handoff

## Diagnosis

`LoupeView.loadSelectedImage()` synchronously called `InspectionDisplay.beginSelection`, which correctly cleared the old frame and assigned a new load ticket. The view body also correctly gates its published frame by `primarySelectedAssetID`. It then awaited foreground preload coordination and the processed ROI cache lookup before the async thumbnail path could publish. During that interval, a previously cached next/previous photo was available in the existing thumbnail memory cache, but the body did not consult it, so the selected-ID gate displayed black.

## Repair

- Added a synchronous, memory-only lookup through `ThumbnailLoader` and `ThumbnailCacheManager`. One shared production key function is used for thumbnail loading/insertion, disk and memory hits, in-flight request deduplication, and the handoff lookup. Its deterministic XMP identity covers every render-affecting develop field, including exposure, temperature, tint, contrast, highlights, shadows, whites, blacks, dehaze, vibrance, saturation, clarity, texture, crop, profile, and grayscale.
- The thumbnail disk namespace is now `com.lumibase.thumbnails.v4`, isolating complete-settings keys from v3 files written under the incomplete key. The handoff remains memory-only and keeps future matching warm hits.
- The loupe body uses this image only when the display has no image for the selected asset. Its existing selected-ID gate still prevents the prior photo from appearing as current. Pending live develop changes disable the shortcut so an older thumbnail is not presented as current.
- On a memory-cache miss, the existing loading indicator remains. The transient frame is labeled “Cached Preview”; held input does not adjust the inspection center from proxy dimensions.
- Scope: this can show an already resident, matching 1600-max-pixel thumbnail immediately while the selected photo's normal load continues. A cold thumbnail miss or ROI-only cache hit may still await preload coordination, holder preparation, or rendering. This does not promise zero black frames in every selection path.
- ROI cache lookup, selection and render revisions, foreground ownership, Fit behavior, and preload scheduling remain in place.

## Regression evidence

`testProductionSelectionHandoffUsesOnlyCurrentPhotoWarmThumbnailAndColdRemainsEmpty` seeds the real `ThumbnailCacheManager` memory cache with `ThumbnailLoader`'s production key for selected photo B, transitions the production `InspectionDisplay` from A to B, and queries the same handoff helper used by the body. It asserts the old frame is cleared, B's cached preview is returned, A cannot be handed off, a pending live develop edit disables the thumbnail, and a cold photo returns no image. `testWarmThumbnailHandoffUsesCompleteProductionDevelopCacheIdentity` checks unchanged and unedited hits plus stale shadows, tint, and exposure rejection against the actual shared production key.

- Cache identity RED: temporarily restored the reviewed partial three-field key and ran the focused handoff regression. It failed two actual assertions: changed shadows and tint still returned the old in-memory image. Unchanged settings, exposure invalidation, and the unedited warm path remained asserted. Log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.2/cache-identity-red.log`.
- GREEN: the final complete-key implementation passed the full suite: 94 tests, 0 failures, 3 opt-in benchmarks skipped. Log: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.2/full-test.log`.
- Existing inspection coverage continues to exercise stale A/B/A completion rejection, frame ownership and ROI provenance, delayed cache invalidation after develop/geometry changes, current native ROI preservation, held input and release, and foreground owner completion.

## Build and delivery

- Release `xcodebuild` succeeded (`BUILD SUCCEEDED`). Log and derived data: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.2/release-build.log` and `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.2/derived/`.
- Delivered app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.2-ROI.app`.
- Verified `CFBundleIdentifier=com.lumibase.LumiBase.Inspection.ROI`, `CFBundleShortVersionString=1.5.2`, and `CFBundleVersion=1.5.2`. The delivered bundle's 6 regular files matched the Release build's SHA-256 hashes at copy time. Hash report: `/Users/kitleong/.hermes/cache/scratch/inspection-1.5.2/artifact-verify.log`.
- No GUI/photo acceptance run was performed. No original photos, sidecars, preferences, or catalog were opened or written. No commit, push, or PR was created.

## Review targets

- [`LoupeView.swift`](../LumiBase/Views/Center/LoupeView.swift): selected-ID gate, synchronous handoff helper, loading display, and unchanged async ROI/thumbnail publication guards.
- [`ThumbnailLoader.swift`](../LumiBase/Services/Image/ThumbnailLoader.swift) and [`ThumbnailCacheManager.swift`](../LumiBase/Services/Image/ThumbnailCacheManager.swift): shared full XMP cache key, v4 disk namespace, and memory-only read.
- [`InspectionTests.swift`](../Tests/LumiBaseTests/InspectionTests.swift): deterministic cached B handoff and cold/live-edit assertions alongside existing ownership and late-completion coverage.
- [`project.pbxproj`](../LumiBase.xcodeproj/project.pbxproj): 1.5.2 build and marketing versions; dedicated ROI bundle ID retained.
- [`LumiBase-Inspection-1.5.2-ROI.app`](/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.2-ROI.app): Release build artifact.
