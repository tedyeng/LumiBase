# LumiBase 1.5.4 folder-switch investigation

## Finding

The supplied live sample does not capture a deadlock or a blocked application call. It records 2,588 main-thread samples in AppKit's event wait (`nextEventMatchingMask` / `mach_msg`) and only one sample inside a main-queue callback. That capture is evidence about that interval only; the user has not confirmed that sampling overlapped a hang. It cannot rule out a freeze at another time.

Source inspection and a deterministic `AppState.openFolder` regression exposed two reproducible lifecycle defects:

1. `openFolder` ran `FolderScanner.quickScan` synchronously on the main actor. The quick scan lists the folder and queries file metadata for every supported image. The A/B/A regression's RED run recorded all three calls on the main thread (`3`, expected `0`).
2. Each folder switch launched an unretained full scan with no cancellation or current-folder check. The regression held all three scans, completed the latest A first, then completed the first A last. The RED run showed `allAssets` change from `latest-A.jpg` to `stale-A.jpg` while the selected folder remained A.

These are demonstrated main-thread disk I/O and stale completion defects, not a demonstrated lock deadlock. They make rapid switches block the UI while listing and permit outdated work to republish state. They do not establish that either defect was the cause of the reported force-quit incident because the supplied sample was idle.

## Changes

- The quick listing now runs in a cancellable detached task. It checks cancellation while filtering and collecting file metadata and reads each file's size and modification date together.
- `AppState` owns a folder-scan task and monotonically increasing generation. A switch cancels the prior task, clears the prior folder's assets, and accepts quick and full scan results only from the current generation. Refresh completions also check cancellation, generation, and folder identity.
- Full directory scans check cancellation during enumeration and process at most four assets concurrently. A canceled scan does not enqueue the rest of a large directory; the small active batch drains before the task returns.
- Folder security-scope ownership is balanced: `AppState` retains one scope for the active folder, releases it when changing folders or deinitializing, and each in-flight scan holds its own scope until it exits. Reopening the same standardized folder does not add another retained scope.
- The scanner closures are injectable so tests can hold and release real `AppState.openFolder` scan completions in a chosen order.
- The shared test fixture helper now writes under `/Users/kitleong/.hermes/cache/scratch/lumibase-folder-switch-1.5.4/test-artifacts`.

## Regression evidence

The new `testRapidFolderSwitchUsesBackgroundQuickScanAndRejectsStaleABACompletion` uses synthetic A and B directories under the Hermes scratch tree and separate controllable scan and decode gates. It holds both phases while switching A/B/A, then returns current and obsolete results in a selected order. The initial pre-fix RED run exercised the scan gate; the separate decode gate was added to the final regression to cover late decode output as well. The pre-fix executable test produced these assertion failures:

- `XCTAssertEqual failed: ("3") is not equal to ("0")` — each synchronous quick scan ran on the main thread.
- `XCTAssertEqual failed: (Optional("stale-A.jpg")) is not equal to (Optional("latest-A.jpg"))` — the first A completion overwrote the newest A result.

After the fix, the focused test passed. It verifies off-main quick scanning, cancellation of both obsolete A/B scans, and that late A/B results cannot replace the latest A generation. This is an actual pre-fix RED run followed by a post-fix run, not a retrospective replay or compiler-error probe.

Full test log: `/Users/kitleong/.hermes/cache/scratch/lumibase-folder-switch-1.5.4/logs/swift-test-final.log` — **93 tests executed, 3 opt-in benchmarks skipped, 0 failures**. This includes the existing preview worker cancellation/ownership, shared RAW decode permit, ROI cache publication, ROI generation and geometry checks, and the new folder lifecycle test.

The project scheme has no Xcode test action, so tests ran through SwiftPM. Release build log: `/Users/kitleong/.hermes/cache/scratch/lumibase-folder-switch-1.5.4/logs/xcodebuild-release-final.log` — `BUILD SUCCEEDED`.

## Bundle

- Release app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.5.4-FolderSwitch.app`
- Version and build: `1.5.4`
- Bundle ID: `com.lumibase.LumiBase.Inspection.FolderSwitch`
- Executable SHA-256 (scratch product and durable copy): `ad1c831482dbdc561eb16a02fce037acb1a6d58f3980736eab6e362802cbbacf`
- Full five-file bundle manifest: `/Users/kitleong/.hermes/cache/scratch/lumibase-folder-switch-1.5.4/bundle-files.sha256`

The durable copy's executable hash matched the Release product. The app was not launched.

## Other audited paths and limits

- `DirectoryWatcher` cancels the old dispatch source and closes its descriptor asynchronously. A callback already queued on the main queue can request a refresh for the current folder, but `AppState` generation and folder checks reject stale scan publication. The watcher itself was not shown waiting on a lock.
- Ready preview/ROI access uses a short `NSLock` around an in-memory dictionary and LRU accounting. No lock cycle or synchronous disk access was found in the ready-frame handoff. RAW base-holder decoding and the speculative ROI worker run away from the main actor; the existing RAW gate serializes those RAW holder decodes.
- The sidebar still reads subdirectory listings synchronously when a folder row is expanded (and selecting a collapsed row expands it). Recent-folder updates also resolve paths and write `UserDefaults` on the main actor. Those paths were audited but were not changed because the new RED test isolates `AppState.openFolder`; their contribution to the reported hang remains unmeasured.
- `ThumbnailLoader` creates detached thumbnail decodes and does not cancel the underlying ImageIO/CIRAWFilter call when a view task is cancelled. The existing RAW decode permit covers `RAWImageLoader`, not every thumbnail request. This may leave background work running across view changes; this investigation did not find a sampled hang or a deterministic regression tying that path to the folder-switch incident, so it remains an open load-shedding risk.
- No GUI was launched or navigated. No user photo, original, sidecar, preferences, or catalog was read or written by the synthetic lifecycle regression. This package regression verifies the demonstrated folder-listing and completion-order defects; it does not prove that the user's reported force-quit symptom is resolved on a real library. A new sample captured during a confirmed hang would be needed to attribute that incident conclusively.
- The separate RAW-detail experiment and its artifacts were not touched. Existing dirty 1.5.1–1.5.3 changes and other work were preserved; nothing was committed or pushed.
