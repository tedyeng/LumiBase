# LumiBase 1.4.3 — pixel inspection release notes

## Behavior

- Hold the left mouse button in the image viewport for temporary native 100% inspection; drag to pan and release to return to Fit unless persistent zoom is active.
- Double-click toggles persistent zoom on completed short second release. Z retains the existing persistent toggle behavior.
- Every eligible down starts inspection immediately, including a repeated press classified by AppKit as clickCount 2. Long holds, drag, wheel use and cancellation disqualify the persistent double-click action.
- Held wheel navigation remains captured in the owning window even outside the viewport. Idle sidebar events are not captured. Release, focus loss, deactivation, detachment and teardown clean up capture.
- Retain the last valid frame through selection/loading/failure. Display loading/unavailable messages honestly; an embedded RAW preview does not qualify as genuine native 100%.
- Full-resolution rendering, orientation handling, decode-WB cache keys and stale-request guards are included in this accumulated inspection branch.

## Proven defect and remaining uncertainty

Previously clickCount 2 toggled persistence immediately and skipped held capture. This could turn persistent zoom off instead of entering a deliberate second hold. The regression failed four assertions before the repair, then passed.

This is not proof of an OS-dropped initial count-1 event. The native surface already accepts activation clicks, remains an unconditional sibling of loading/image branches, and does not steal first responder. OSLog subsystem `com.lumibase.inspection` records event receipt, release classification and loading/native/error state for further diagnosis. No photo paths are logged.

## Validation

- Full `swift test`: 46 tests, zero failures.
- Debug `xcodebuild`: BUILD SUCCEEDED with separate `com.lumibase.InspectionTest` bundle identifier.
- Independent read-only review found no concrete changed-press-logic defects.
- Version/build 1.4.3; durable inspection app's seven files matched the build product by SHA-256.
- Native-method/routing synthetic tests cover held/outside wheel, duplicate release, lifecycle cleanup, persistent/temporary zoom, callback refresh, stale frames and unsupported native decoding.

No GUI acceptance or real-camera performance claim: optional absent camera fixtures early-return. Existing unused-variable test warnings and the nonblocking AppIntents metadata warning remain.

## Local artifact and follow-up

Local app: `/Users/kitleong/projects/LumiBase-builds/LumiBase-Inspection-1.4.3.app` (not committed).

Detailed development history: [pixel-inspection-progress.md](pixel-inspection-progress.md).

Next-step research, not shipped functionality: [inspection-performance-research.md](inspection-performance-research.md). No adjacent prefetch is enabled in 1.4.3. No source-photo or sidecar edits are part of this release.
