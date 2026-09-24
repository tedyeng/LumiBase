# Inspection 1.5.1: stale ROI develop settings race

## Cause

At merged HEAD `e936858e91fc364fae4e377e1cd08bfb76acc01c`, `loadSelectedImage()` captured active XMP, awaited `ProcessedROICacheService.cachedMatch`, and accepted a match using only the selection load revision and selected asset ID. A develop edit during that await could therefore publish a bitmap rendered with earlier settings. The fallback path also reused the captured XMP when the cache lookup missed.

The queued `DispatchQueue.main.async` XMP observers had the same stale-capture shape: their queued `newXMP` could outlive the selection/settings that caused the notification.

## Repair

- Added a production publication seam that compares the full captured/current ROI publication state after the async lookup: asset ID, load and render generations, full XMP settings identity, zoom/ROI enabled state, center, viewport, and backing scale.
- Cache publication remains the first fast path when those inputs are unchanged. Rejected/missing results fall through to holder loading with freshly resolved active settings. The existing post-hit holder warmup still reloads if settings change while RAW decode is suspended, keeping its base holder/Fit render aligned with the latest settings, including white balance.
- Deferred XMP observer blocks now resolve settings from the current selection when they execute.
- Existing cached ROI transition, Fit/held/persistent zoom behavior, and foreground/preloader owner completion paths were retained.
- Bumped both Xcode version fields to 1.5.1; bundle ID remains `com.lumibase.LumiBase.Inspection.ROI`.

## Red/green evidence

The regression test suspends the actual production publication seam behind a controlled async query, changes active exposure/temperature settings, then resumes it with an old cached bitmap. Against the former weak guard it fails on the intended assertion:

```text
XCTAssertNil failed: "old-cached-bitmap" - a cached ROI rendered with old exposure/temperature must never publish after current settings change
Executed 1 test, with 1 failure
```

The restored full-state guard passes the same test. Additional deterministic seam tests cover unchanged-settings cache hit, A/B/A selection generation, changed ROI center, current-settings fallback (including white balance), and deferred observer resolution. Existing tests cover cache owner token cleanup, preview-selection completion after holder warmup, and Fit/held/persistent transitions.

## Verification

- Full `swift test`: 92 tests executed, 0 failures, 3 opt-in benchmark tests skipped. The skip messages state that benchmark environment variables and manifests are required.
- `xcodebuild -project LumiBase.xcodeproj -scheme LumiBase -configuration Release ... build`: succeeded with code signing disabled; final build used the fully restored guard.
- Delivered app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.1-ROI.app`. Verified `CFBundleIdentifier=com.lumibase.LumiBase.Inspection.ROI`, `CFBundleShortVersionString=1.5.1`, and `CFBundleVersion=1.5.1`. All 5 regular files in the copied app have SHA-256 hashes identical to the Release build output.
- Full red and green Swift test logs and Release derived data are under `/Users/kitleong/.hermes/cache/scratch/roi-1.5.1/` (`red-test.log`, `green-test.log`, `derived/`).
- No GUI/photo acceptance run was performed; GUI acceptance remains for the user. No original files, sidecars, preferences, or catalog were opened or written. No commit, push, or PR was created.

## Review targets

- [`LoupeView.swift`](../LumiBase/Views/Center/LoupeView.swift): async publication guard, current-settings fallback, holder warmup, and deferred observer resolution.
- [`InspectionTests.swift`](../Tests/LumiBaseTests/InspectionTests.swift): delayed-query red/green assertions and production-seam coverage.
- [`project.pbxproj`](../LumiBase.xcodeproj/project.pbxproj): version bump; dedicated bundle ID preserved.
- [`LumiBase-Inspection-1.5.1-ROI.app`](/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.1-ROI.app): reviewable Release build artifact.
