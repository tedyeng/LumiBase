# Pixel inspection checkpoint

## 1.4.3 first/repeated press investigation

Durable app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.4.3.app`; version/build 1.4.3, bundle `com.lumibase.InspectionTest`. All 7 copied files SHA-256 match the successful xcodebuild product. No app launched; prior bundles preserved.

Proven defect: 1.4.2 passed NSEvent.clickCount directly to the owner and explicitly skipped capture for count 2. The owner ended held mode and toggled persistence on that down. A rapid repeated down classified as the second click therefore was not a hold; with persistent zoom already enabled it turned zoom off. The new regression `testRepeatedDownAlwaysHoldsAndLongSecondPressDoesNotTogglePersistent` failed four assertions before production edits, then passed. This proves a repeated-press defect, NOT a demonstrated OS-dropped first count-1 event.

Fix: every in-bounds down immediately starts temporary inspection and capture, without changing keyboard focus. Only a completed short second click toggles persistence, after ending the hold. Short means no longer than NSEvent.doubleClickInterval, no drag beyond 4 points, no wheel use, and release inside. Previous long/drag/wheel/cancel gestures cannot qualify as the first click. Monitor-delivered mouseUp and subsequent native delivery remain idempotent. A quick repeated press below that threshold is necessarily treated as a double click; intent cannot otherwise be inferred. Z remains on the unchanged AppState notification path.

Investigation: acceptsFirstMouse already returned true and remains so; Surface does not accept first responder or steal key handling. Surface is an unconditional sibling of the image/loading/error branches, not inside the conditionally replaced image view, and owner callback refresh does not itself dismantle capture. Existing lifecycle cleanup, holder/selection/revision checks and loading/unsupported-native error captions remain. No evidence established window activation or SwiftUI replacement as the actual missing-first-event cause. Debug OSLog under subsystem `com.lumibase.inspection` records native down count/key-window/owner, capture end/release classification, and SwiftUI intent loading/native-frame/error flags (no photo paths). Capture live with `log stream --level debug --predicate 'subsystem == "com.lumibase.inspection"'` if a genuine initial down still fails.

Verification: full `swift test` passed **46 tests, 0 failures**. New matrix test `testShortDoubleClickTogglesOnceButDragWheelAndCancelDoNot` checks toggle-on and toggle-off, immediate second-down capture, monitor/native release duplication, long-first rejection, drag/wheel/cancel rejection, acceptsFirstMouse and non-first-responder policy. Existing held outside wheel, foreign-window/idle routing, focus/close/detach, temporary/persistent release, owner refresh, stale-display/render guards, and unsupported-native tests pass. Matrix coverage was added after the primary RED/GREEN fix; only the primary failing regression is claimed as pre-fix reproduction. Full xcodebuild Debug with the separate bundle ID returned BUILD SUCCEEDED; `git diff --check` passed. Existing unused-value test warnings and AppIntents metadata warning remain.

Independent read-only Codex review found no concrete defects in the changed press logic, monitor/idempotence, idle sidebar routing or stale guards. Report: `LumiBase-builds/press-review.txt`; logs `press-{red,green,tests,build,review}.log`. GUI delivery/activation, physical Retina display, and real-camera RAW acceptance were NOT exercised. Optional absent camera fixtures still early-return. No originals/sidecars edited, no installed app overwrite, no commit/push/PR. Earlier uncommitted loader/render changes preserved unchanged in this task.

## 1.4.2 held-wheel capture repair

Durable app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.4.2.app`, version/build 1.4.2, bundle `com.lumibase.InspectionTest`. All 7 copied files match build-product SHA-256; prior bundles including 1.4.1 remain untouched. App not launched.

Root cause: native mouse dragging retains the gesture owner, but wheel delivery remains hit-tested; the old bridge also explicitly rejected coordinates outside its bounds. A temporary local scroll/mouseUp monitor now belongs only to the Surface whose single left-down began inside the viewport. Held wheel in the same window uses the existing throttle/precision/momentum gate regardless of viewport coordinates. The monitor consumes wheel events and a shared event-identity guard prevents duplicate accumulation through native scrollWheel. Other-window wheel and idle sidebar events pass through. Double-click persistent-zoom toggles do not start capture.

Cleanup is idempotent on delivered mouseUp (including outside), missed-button-up detection on the next monitored event, cancelOperation, app deactivation, owning-window focus loss/close, detachment and representable teardown; deinit removes remaining tokens defensively. MouseUp is passed onward after cleanup so AppKit can finish native tracking. Observer/monitor closures are weak; UI event and notification work runs on main. No first-responder change or new keyboard monitor: AppState still owns keyboard shortcuts, including Escape/G switching away and dismantling the surface. Temporary release returns Fit; persistent release retains 100%. Source position, wheel gate and all 1.4.1 renderer/loader/frame-retention code remain unchanged.

Verification: `swift test` **44 tests, 0 failures**; `xcodebuild -project LumiBase.xcodeproj -scheme LumiBase -configuration Debug -derivedDataPath /Users/kitleong/.hermes/cache/scratch/LumiBase-InspectionBuild CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=com.lumibase.InspectionTest build` **BUILD SUCCEEDED**. `git diff --check` and added-line security scan passed. Build warning: AppIntents metadata skipped (no dependency). Three added tests cover outside held wheel, capture routing/precise duplicate guard/release/idle/recovery/cancel/deactivation/persistent behavior, and window close/focus/detach/foreign-window scope. First regression was observed failing an actual 0-vs-1 assertion before the fix; monitor tests first failed because the capture API did not exist. The additional window-lifecycle coverage was added after implementation. Logs: `LumiBase-builds/capture-{red,green,red2,green2,tests,build}.log`.

Limits: synthetic NSEvent calls and routing-seam tests are **not OS-delivered GUI acceptance**. Previously unavailable GUI permissions were not changed. Only same-owning-window wheel events are captured; outside-window events directed to another app are not available to this local monitor, and continuous navigation outside the app window is not promised. AppKit-delivered release still cleans up; deactivation and a later event with the left button up recover missed releases. Real held-drag/wheel/sidebar acceptance remains for user testing. Optional real-camera fixture tests still early-return when fixtures are absent. No photo/sidecar mutations, commit, push, PR, installed-app overwrite, or independent review. Existing uncommitted work preserved.


## 1.4.1 black-frame repair

Durable app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.4.1.app`, bundle `com.lumibase.InspectionTest`. Separate xcodebuild succeeded; all 7 copied bundle files matched SHA-256. No running LumiBase executable was found immediately before copying; the old 1.4.0 bundle was nevertheless preserved. No app was stopped or launched.

Root causes: selection explicitly cleared both visible images, and zoom hid any image until native render finished. Thumbnail preparation also serialized native loading. RAW cache compared post-decode exposure to a deliberately neutral decode, causing unnecessary misses; nil WB could incorrectly reuse an explicitly adjusted decode. Core Image output was deferred, allowing raster work to occur on first display.

Changes: one staged visible frame retains image/filename/dimensions through load, zoom and failure; latest-request valid results replace it. Always-visible pending/error captions identify requested and retained images independently of the info HUD. Non-native/pending zoom says `Preparing native 100%`. Native/thumbnail preparation overlaps; held navigation does not replace an existing image with a small thumbnail. Completed native pixels survive release/reentry without rerender. Exact decode-WB cache keys exclude post-decode exposure, and cancellation propagates to detached decoding. Native CGImage creation is nondeferred on the existing coalescing background render queue. No adjacent prefetch or unlimited full-resolution cache was added; the existing one-holder cache remains.

Verification: **41 tests, 0 failures**; added staged-display retention/failure/stale-result, decode-settings key, and synthetic 24MP decode/render/switch tests. Missing-type RED runs were captured before the new state/key implementations. Existing held-wheel/mouse/release/Retina-coordinate tests pass. `git diff --check` passes. Tests are state/native-method integration, not OS-delivered GUI tests.

Synthetic detailed-noise JPEG fixture, 6000×4000, final measured milliseconds (decode / native render plus forced bitmap draw): A first **85.77 / 68.00**, A cached **0.08 / 68.85**, B **85.78 / 68.23**, back to A **84.54 / 67.20**. Earlier deferred-image timing appeared sub-millisecond until a forced bitmap draw revealed 87–157ms; do not report object creation as display speed. These are synthetic JPEG measurements, not camera RAW timings or end-to-end frame latency. The benchmark creates and deletes only its own temporary files.

Limitations: real-camera fixtures absent (existing optional RAW tests early-return); GUI permissions remain unavailable, so actual smoothness/Retina visual acceptance needs user testing. In-flight GPU work cannot be interrupted; pending renders coalesce and stale completions are rejected. No broad color/exposure changes, source photos, sidecars, commits, pushes or PRs. Logs: `LumiBase-builds/flash-{red,red2,tests,build}.log`. Previous uncommitted edits preserved.


Branch: feature/pixel-inspection. Baseline swift test passed. Version 1.3.0 -> 1.4.0.

Implemented native viewport mouse surface, temporary hold and persistent zoom state, normalized source center/pan, backing-scale sizing, wheel interval/precision/momentum gate, full-resolution processed rendering, oriented raster decode, generation guards for selection/develop/zoom requests.

Initial state test observed missing-feature compilation failure then passing. Additional wheel/revision/full-resolution tests likewise observed missing-feature compilation failure. Additional native-event/coordinate/gating regressions were added after implementation (do not claim every test followed strict RED/GREEN).

Final verification: `swift test` executed 36 tests, 0 failures; 6 are new inspection tests. The full-resolution render test uses a synthetic 3000×20 CIImage with a deliberately smaller proxy and verifies native output dimensions. The native-event test calls the real NSView mouseDown/mouseDragged/mouseUp methods with synthetic NSEvents; this is NOT end-to-end GUI delivery.

`xcodebuild -project LumiBase.xcodeproj -scheme LumiBase -configuration Debug -derivedDataPath /Users/kitleong/.hermes/cache/scratch/LumiBase-InspectionBuild CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=com.lumibase.InspectionTest build` returned **BUILD SUCCEEDED**. The built bundle reports version 1.4.0 and is separate from the installed app.

App: `/Users/kitleong/.hermes/cache/scratch/LumiBase-InspectionBuild/Build/Products/Debug/LumiBase.app`

Self-review fixes: preserve normalized anchor before native dimensions arrive (do not clamp against the thumbnail); bind holder to selection ID; use existing coalescing render queue rather than unbounded detached GPU renders; release temporary inspection when app resigns active. Existing global keyboard/rating handling and AdobeColorPipeline are untouched. `git diff --check` passed; added-line security scan found no matches. No independent reviewer or commit.

Logs: ~/.hermes/cache/scratch/lumibase-{baseline,red,green,red2,tests,xcodebuild}.log.
Separate build: ~/.hermes/cache/scratch/LumiBase-InspectionBuild (test bundle ID).
No source photos, installed app or app preferences touched. No commits/push/PR.
GUI validation not performed: computer-use capability is not exposed in this subagent tool catalog and peekaboo is not installed. Parent should complete an isolated synthetic-photo GUI session before calling this fully accepted. App was not launched. Final logs are `~/.hermes/cache/scratch/lumibase-tests-final.log` and `lumibase-xcodebuild-final.log`.

## Independent review and verification

Reviewed the complete tracked diff, inspection tests, loader/renderer, selection ownership and this checkpoint. Fixed three concrete issues:

- Added decoder provenance (`supportsNativeInspection`). Embedded thumbnails and unverified ImageIO RAW fallbacks remain available in Fit but are rejected for native 100%; the viewport explicitly explains that native inspection is unavailable rather than enlarging the preview and claiming genuine source pixels.
- Render completion now returns nil on failure, not silence. Decode/render failures stop waiting and show an unavailable/error state when no eligible image can be displayed. Revision/selection guards still reject stale completions.
- Restored the immediate 1440px interactive Fit render plus a 200ms idle refinement, avoiding the unnecessary display-resolution/decode-on-every-slider-update regression. Native inspection still uses full-resolution rendering.

Added a preview-only holder/native-render rejection + asynchronous failure-completion regression (observed missing-provenance compilation failure before implementation), and a real NSView-method synthetic wheel/down/up regression that refreshes callbacks across selection, verifies held position, release-to-Fit and persistent-100 release behavior. These are synthetic event tests, not OS-dispatched GUI tests.

Final `swift test`: **38 tests, 0 failures**, including **8 inspection tests**. `xcodebuild` with the distinct InspectionTest bundle ID: **BUILD SUCCEEDED**. Only build warning: AppIntents metadata extraction skipped because no AppIntents dependency exists. `git diff --check` passed; added-line security scan found no matches. No commit/push/PR.

Durable deliverable: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection.app` — version **1.4.0**, bundle ID **com.lumibase.InspectionTest**. All 7 copied bundle files were SHA-256 compared with the build products, with zero mismatches. Executable SHA-256: `db5244bec1ebfcd69db430844c284c6f4604ca8337fad311b193ee8a3883b162`.

Durable logs: `/Users/kitleong/projects/LumiBase-builds/lumibase-review-{tests,build,red}.log`.

GUI attempt blocked at prerequisite discovery: `peekaboo` is not installed and `osascript -e 'tell application "System Events" to get UI elements enabled'` returned **false**. No permissions were changed and the app was not launched; no user archive or preferences were touched. **Do not claim GUI acceptance.** Actual Retina pixel alignment, real-camera RAW decoding/performance, double-click routing, OS-delivered held-wheel selection/release, sidebar scroll isolation and live-slider responsiveness still need an isolated synthetic-photo GUI session. Existing optional real-camera tests early-return when local fixtures are absent, so the passing suite does not establish camera coverage.
