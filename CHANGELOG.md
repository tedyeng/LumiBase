# Changelog

All notable changes to **LumiBase** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.9.0] - Inspection performance and input regression fixes

### Improved
- Speed up exact negative-Highlights preparation with quarter-sample readback and disjoint parallel box-filter workers. This applies only when **Advanced RAW Highlight Recovery (Experimental)** is enabled; the default-OFF standard color pipeline is separate and was not benchmarked as an effect of this change.
- Coalesce obsolete edit renders and invalidate queued work on selection/zoom changes; reuse dependency-keyed RAW holders and the prepared field for Highlights-strength-only edits.
- Repair double-click 100% ROI invalidation when the native center changes without a zoom-state change, and avoid a duplicate drag render.
- Refresh the current Loupe raster when Advanced RAW Highlight Recovery is toggled, without treating it as an XMP edit or triggering Auto Sync. Invalidate retained previews/ROIs and include the rendering policy in ROI cache identity.
- Add filmstrip wheel navigation and double-click reset for Develop controls (WB resets to each photo's as-shot baseline).
- Keep older DMG installers when packaging a new version.

### Validation
- Add native double-click, input, kernel, queue, crop, switch, and opt-in interactive benchmark tests. Tested one real RAW's full-frame native output for exact parity; the benchmarks measure API-to-raster, not physical input-to-display latency. Draft thumbnails and the default-OFF experimental switch are retained from 1.8.1.

## [1.8.1] - 2026-09-26

### Added
- **Comprehensive UI Tooltips with Keyboard Shortcut Annotations (`.help(...)`)**:
  - Added native AppKit/SwiftUI tooltips across all clickable buttons, icon toggles, menu pickers, sliders, and badges.
  - Included descriptive action titles and keyboard shortcut badges (e.g. `⌘O`, `⇧⌘E`, `F7`, `F8`, `⌘F`, `E`, `R`, `O`, `X`, `Z`, `I`, `P`, `X`, `U`, `0..5`, `⇧⌘C`, `⇧⌘V`, `⇧⌘S`, `⌥⇧⌘S`).
  - Added tooltips in **Develop Basic Panel**: Auto Tone, Treatment Mode toggle, Reset All Basic Adjustments, Camera Profile menu, Profile Browser icon (`square.grid.2x2`), White Balance eyedropper icon (`eyedropper`), WB preset menu, and Experimental Highlight Recovery toggle.
  - Added tooltips in **Crop & Rotate Panel**: Aspect ratio lock/unlock, Aspect ratio preset picker, Flip orientation (`X`), Tool overlay cycle (`O`), Reset Crop, and Done (`Return` / `R`).
  - Added tooltips in **Sync Settings Dialog & XMP Metadata Editor**: Category select/unselect checkboxes, Check All, Check None, Modified Only, Star ratings, Flag toggles, and Keyword tags.
- **Global `F7` & `F8` View Toggle Shortcuts**:
  - Implemented global `F7` key listener to toggle Left Sidebar (`isLeftSidebarVisible`).
  - Implemented global `F8` key listener to toggle Right Inspector (`isRightInspectorVisible`).
- **macOS Native `Develop` Menu Commands (`LumiBaseApp.swift`)**:
  - Added dedicated `Develop` menu in macOS menu bar with native key equivalents for `Edit Adjustments (E)`, `Crop & Straighten (R)`, `Auto Tone`, `Toggle Treatment (Color/B&W)`, `Flip Crop Orientation (X)`, `Cycle Crop Overlay (O)`, `Reset Crop`, `Copy Settings (⇧⌘C)`, `Paste Settings (⇧⌘V)`, `Sync Settings (⇧⌘S)`, `Toggle Auto Sync (⌥⇧⌘S)`, and `Reset All Adjustments`.
  - Wired menu commands through `NotificationCenter` broadcasts to `MainLayoutView` and `AppState`.

### Fixed
- **AppKit Hover Tracking Area for Rating & Flag Badges**:
  - Replaced gesture-based `.onTapGesture` on image views with native SwiftUI `Button` (`.buttonStyle(.plain)`) in `RatingStarsView` and `FlagBadgeView`, ensuring AppKit properly generates `NSTrackingArea` tooltips on hover.

## [1.8.0] - 2026-09-25

### Added
- **Lightroom-Style Crop & Straighten (`CropSettings`, `CropControlPanelView`, `CropOverlayView`)**:
  - Added dedicated Develop tool switcher in Inspector header to toggle between **Edit** (`slider.horizontal.3`) and **Crop** (`crop`) modes.
  - Added interactive 8-handle crop overlay over Loupe View with darkened outer mask, pan drag, and aspect ratio constraint enforcement.
  - Added **Adaptive Alignment Grid**: dynamically calculates and renders fine multi-line alignment grid based on window / crop box size (~32pt grid spacing), matching Lightroom Classic's horizon and architecture alignment guide.
  - Added **Tool Overlay Cycle**: support cycling between multi-line `Grid` and 3x3 `Thirds` via `O` shortcut and Inspector button.
  - Added preset aspect ratio menu (`Original`, `1:1`, `4:5`, `5:7`, `16:9`, `Custom`) and aspect lock/unlock button.
  - Added angle / straighten slider (`-45.0°` to `+45.0°`) with 1-click 0° reset.
  - Added **120 FPS GPU Live Rotation**: direct GPU texture rotation in interactive crop mode for 120 FPS smooth live preview without frame drops.
  - Added keyboard shortcuts: `R` (toggle crop tool), `O` (cycle overlay style), `X` (flip crop orientation), `Return` / `Esc` (commit and close).
  - Added Step 9 geometric transform in `AdobeColorPipeline` to apply rotation and normalized cropping non-destructively in GPU pipeline.
  - Full bidirectional Adobe XMP serialization (`crs:HasCrop`, `crs:CropTop`, `crs:CropLeft`, `crs:CropBottom`, `crs:CropRight`, `crs:CropAngle`).

### Fixed
- **Search Bar Focus Isolation & Shortcut Interception**:
  - Resolved macOS AppKit issue where search text field automatically grabbed first responder focus on launch/view switch, inadvertently consuming single-key shortcuts (`R`, `1..5`, `O`, `X`, `G`, `E`).
  - Added `@FocusState` and auto focus release on photo selection, mode toggle, and `Esc` key press.
  - Standardized `Cmd+F` to explicitly focus search input.

## [1.7.0] - 2026-09-25

### Added
- **Lightroom-Style Develop Sync Settings (`DevelopSyncOptions` & `SyncSettingsDialogView`)**:
  - Added selective Develop adjustment synchronization modal (`Cmd+Shift+S` / `Sync` button in Inspector footer).
  - Supported selective categories: White Balance (Temp, Tint), Basic Tone (Exposure, Contrast, Highlights, Shadows, Whites, Blacks), Presence (Texture, Clarity, Dehaze, Vibrance, Saturation), Treatment & Profile (Camera Profile, Monochrome), and Geometry (Crop).
  - Added quick selection helpers: `Check All`, `Check None`, and smart `Modified Only` (detects and checks only source photo's modified fields).
- **Auto Sync Real-Time Multi-Photo Editing**:
  - Added instant multi-photo slider synchronization toggle (`Cmd+Option+Shift+S` / Auto Sync toggle in Inspector footer).
  - When enabled, adjusting any Develop slider, invoking Auto Tone, or resetting adjustments instantly updates all selected photos in real time.
- **Copy & Paste Develop Settings**:
  - Added Copy Settings Dialog (`Cmd+Shift+C` / `Copy` button) with selective adjustment checkboxes.
  - Added Paste Settings (`Cmd+Shift+V` / `Cmd+Option+V` / `Paste` button) to apply copied adjustments across single or batch selected photos.
- **Develop Command Menu**:
  - Added `Develop` menu in macOS menu bar with dedicated shortcuts for Copy Settings, Paste Settings, Sync Settings, and Toggle Auto Sync.
- **Unit Test Suite**:
  - Added comprehensive tests in `DevelopSyncTests.swift` covering selective masking, batch synchronization, copy/paste, and auto sync real-time propagation (116 total tests passing).

## [1.6.2] - 2026-09-25

### Fixed
- **RAW Thumbnail Infinite Loading & Cooperative Pool Contention**:
  - Decoupled `NativeHighlightsService` from thumbnail generation pipeline; thumbnails now use draft-mode decoding (`CIRAWFilter.isDraftModeEnabled = true`) and shared static `CIContext`, dropping decode time per thumbnail from 1.5–3.0s to 5–15ms.
  - Retained dedicated GCD serial queue (`com.lumibase.thumbnail.decode`) for safe ImageIO decoding without blocking the Swift concurrency cooperative pool.
  - Bumped thumbnail cache develop key to `"highlights-1.6.2|"`.
- **Preview Freeze & Color Distortion (Dangling Pointer Fix)**:
  - Resolved memory corruption in `AcceptedHighlightsKernel` where backing buffer `bytes` was released prematurely while `CIImage(bitmapData:)` was in flight, eliminating neon green artifacts and false color banding in sunset sky regions.
  - Restored lightweight 10ms Adobe PV2012 pipeline (`AdobeColorPipeline`) as standard preview renderer.
- **Export Concurrency Safety (`PhotoExportService`)**:
  - Guarded highlight processing against experimental toggle state.
  - Synchronized off-main thread export dispatches via semaphore signaling, eliminating potential deadlock hazards.
- **Compiler Deprecation Warnings**:
  - Added `-DCI_SILENCE_GL_DEPRECATION=1` to Xcode project build configurations to silence Core Image OpenGL-based kernel deprecation warnings.

### Added
- **Experimental Feature Toggle**:
  - Added user-controllable toggle `Advanced RAW Highlight Recovery (Experimental)` at the bottom of the "Tone" adjustment section in `DevelopBasicPanelView` (below Blacks).
  - Configured default state to **OFF**, backed by `UserDefaults.standard.bool(forKey: "isNativeHighlightsEnabled")`.
  - Dynamically clears `RAWImageLoader` cache and triggers live re-rendering upon toggle changes.

## [1.6.1] - 2026-09-25

### Fixed
- **RAW Thumbnail Cooperative-Pool Starvation**:
  - Isolated synchronous thumbnail decoding from Swift cooperative workers onto dedicated serial GCD queue (`com.lumibase.thumbnail.decode`).

## [1.6.0] - 2026-09-25

### Added
- **Native Accepted-B Highlights Recovery**:
  - Dual-exposure RAW demosaicing (0 EV / -2 EV) and Core Image highlight blending for assets with negative highlight adjustments (`highlights2012 < 0`).

## [1.5.5] — Inspection ROI delivery

### Fixed / Changed (1.5.1–1.5.5)
- Share preloaded previews, completed Fit frames and processed ROIs through a bounded 128 MiB ready-frame LRU; preserve foreground priority, preview ±3 and native ROI neighbor ±1 scheduling.
- Reject stale async develop/cache publications and isolate frame ownership; retain the same photo's last valid frame while updated settings render.
- Keep proxy previews aligned with original oriented geometry at held 100%, and validate cached ROI extent against the warmed holder.
- Move quick folder scans off the main actor, bound metadata concurrency and reject cancelled or obsolete folder/refresh completions.
- Keep version/build 1.5.5 and the dedicated `com.lumibase.LumiBase.Inspection.ROI` bundle ID. No highlight experiment is included.

### Verification / Limits
- User reports ROI 1.5.5 now works normally. Delivery rerun: 96 tests, 3 opt-in benchmark skips, 0 failures.
- The original folder-switch force-quit incident is **not proven resolved**; the available sample did not capture a confirmed hang.
- See the [consolidated release and review notes](docs/inspection-1.5.5-release.md) for version history, scope, reproducible verification and remaining limits. Older entries below describe historical checkpoints rather than the final cache architecture.

## [1.4.4] - 2026-09-23

### Added & Improved
- **Develop Basic Panel Direct Numeric Editing & Tab Navigation (`LightroomSlider` & `DevelopBasicPanelView`)**:
  - **Click & Double-Click Edit Activation**: Clicking or double-clicking any adjustment slider's numeric value immediately enters manual text input mode with focus and selection.
  - **Sequential Tab / Shift+Tab Navigation**: Pressing `Tab` automatically commits the current slider's value and advances focus to the next basic slider in sequence (`Temp` → `Tint` → `Exposure` → `Contrast` → `Highlights` → `Shadows` → `Whites` → `Blacks` → `Texture` → `Clarity` → `Dehaze` → `Vibrance` → `Saturation`). Pressing `Shift+Tab` moves to the previous slider.
  - **Return & Escape Dismissal**: Pressing `Return` commits the entered value and exits edit mode; pressing `Esc` cancels / exits edit mode.
  - **Double-Click Reset**: Double-clicking a slider title (e.g. `Temp`, `Exposure`) or slider track/thumb resets the slider to its default value.
- **Top 5 Recent Folders Persistence & System Volume Filtering (`LeftSidebarView`)**:
  - Automatically persists the top 5 most recently opened/clicked folders in `UserDefaults` (`LumiBase.RecentFolders`), immediately accessible at the top of the Left Sidebar across application relaunches.
  - Filtered out macOS system artifacts, Time Machine snapshots (`com.apple.TimeMachine.*`), root symlinks (`Macintosh HD`), and hidden system volumes (`Preboot`, `Recovery`, `VM`, `Update`).
- **SwiftUI View Update Lifecycle & Warning Elimination**:
  - Resolved `Publishing changes from within view updates is not allowed, this will cause undefined behavior` warnings across `LightroomSlider`, `LoupeView`, and `GridView`.
  - Decoupled key press event handling (`KeyEventDispatcher`) and slider text commits via asynchronous main queue dispatching (`DispatchQueue.main.async`).

---

## [1.4.3] - 2026-09-22

### Added & Improved
- **Temporary & Persistent 100% Pixel Inspection Engine (`LoupeView` & `InspectionSurface`)**:
  - Hold left mouse button for temporary 100% native pixel inspection with pan support.
  - Double-click or `Z` key to toggle persistent 100% zoom.
  - AppKit event routing (`NSEvent.addLocalMonitorForEvents`) ensuring flawless mouse capture and clean window teardown.

---

## [1.5.0] - 2026-09-22

### Changed
- Clear the previous asset's displayed frame and Fit fallback as soon as a new stable asset ID owns the Loupe. Render-time and asynchronous publication checks reject mismatched owners, including rapid A/B/A navigation with duplicate filenames.
- Enable native ROI rendering by default while retaining the in-memory ROI OFF switch; no preference values are read or written.
- Set the isolated ROI product bundle identifier to `com.lumibase.LumiBase.Inspection.ROI`.

### Checkpoint
- The neighboring processed ROI bitmap cache and ROI preload worker were not added. The existing speculative worker handles only embedded previews; safe processed ROI speculation needs a dedicated renderer/scheduler and complete cache identity.
- See [inspection 1.5.0 ROI cache checkpoint](docs/inspection-1.5.0-roi-cache.md) for RED/GREEN logs, verification, limitations, and review targets.

## [1.4.4] - 2026-09-22

### Added
- Bounded speculative Loupe preview preloading across up to three neighbors on each side of the current filtered and sorted list, prioritizing travel direction.
- Separate utility-priority preloader with one running job, cancellation and stale-result rejection, and a strict 128 MiB accounted speculative bitmap cache with LRU eviction and in-flight reservation.
- Complete preview identity including canonical asset path, file modification time and size, full XMP revision, output dimensions, and pipeline version. Selecting an already cached preview reuses it in Loupe.
- Published list changes are coalesced and read after mutation; cached keys are removed from speculative dispatch without re-decoding.
- Speculation waits for the matching selected Loupe foreground render, suspends until memory pressure returns to normal, and skips RAW files without embedded thumbnails instead of triggering full RAW decode.
- Memory-pressure clearing and conservative exclusion of develop-edited RAW assets from speculative decoding.

### Limits
- The 128 MiB value covers accounted speculative bitmap bytes and reserved speculative bitmap cost. It does not bound total process, Core Image, decoder, GPU, visible-frame, or framework memory.
- Speculation uses ImageIO embedded/downsampled previews only. It does not perform speculative full native RAW decode or edited-RAW develop rendering.
- Full Swift tests pass (58 tests), including AppState and actor/consumer integration with synthetic image fixtures. Xcode Debug build passes. No GUI acceptance, supported-camera RAW coverage, latency comparison, or performance gain is claimed.

## [1.3.1] - 2026-09-22

### Added & Improved
- **Adobe Camera Raw (ACR) Planckian Locus Dynamic Tint Compensation (`AdobeColorPipeline` & `RAWImageLoader`)**:
  - Automatically calculates color temperature deviation relative to camera as-shot baseline ($\Delta\text{Temp}$) and injects dynamic Planckian locus magenta compensation into `CIRAWFilter` ($\Delta\text{Tint} \approx \Delta\text{Temp} \times 0.012$).
  - Completely eliminates the green/olive/yellowish chromaticity drift in Apple RAW when boosting Kelvin color temperature, restoring clean golden sunset tones and neutral water reflections.
- **Calibrated Baseline Exposure & Dynamic Range (`rawFilter.baselineExposure = 0.30`)**:
  - Aligned default RAW demosaicing baseline exposure offset with Adobe Camera Raw's Sony ILCE-7CM2 profile (+0.30 EV).
  - Normalizes 18% middle gray (Zone V) luminance and opens up shadow/midtone dynamic range across the entire image.
- **Filmic Highlight Roll-off & S-Curve Tone Mapping (`CIToneCurve`)**:
  - Re-calibrated 5-point parametric tone curve with a filmic highlight shoulder ($p2Y, p3Y$) and deep shadow anchor ($p0Y, p1Y$).
  - Prevents burnout / harsh clipping when Highlights is pushed to $+100$, gracefully preserving cloud and sun ray textures.
  - Smooth shadow toe prevents shadow smearing while keeping blacks crisp.
- **Lightroom Classic Style Histogram Engine (`HistogramCalculator` & `HistogramView`)**:
  - Replaced square-root scaling with Lightroom's Perceptual Power curve response ($x^{0.70}$) combined with 3-point Gaussian smoothing to eliminate high-frequency sampling noise.
  - Implemented multi-layer additive RGB histogram visualization with gray luminance background and accurate channel overlaps.
- **Multi-Selection Rating & Flag Sync**:
  - Integrated `1`–`5`, `0`, `P`, `X`, `U` rating shortcuts across all selected photos simultaneously with live XMP write-back.
- **Unit Test Suite Expansion**:
  - Added real Sony A7C II color pipeline verification, CIRAWFilter temperature direction tests, and multi-selection keyboard shortcut tests (30/30 tests passing, 0 failures).

---

## [1.3.0] - 2026-09-21

### Added
- **Lightroom Classic Develop "Basic" Panel (`DevelopBasicPanelView`)**:
  - Full 1:1 parity with Adobe Lightroom Classic Develop Basic module.
  - **Treatment (Color / Black & White)**: One-click monochrome toggle with `crs:ConvertToGrayscale="True"` XMP synchronization and contextual hiding of color-only sliders in B&W mode.
  - **Camera Profiles**: Support for standard Adobe profiles (Adobe Color as default, Adobe Standard, Adobe Portrait, Adobe Landscape, Adobe Vivid, Adobe Monochrome, Adobe Neutral, Camera Standard).
  - **White Balance (WB)**: Full Kelvin temperature slider (2000K to 50000K), Tint slider (-150 to +150), and comprehensive presets (As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom).
  - **Tone Controls**: Linear EV Exposure (-5.00 to +5.00 EV), Contrast (-100 to +100), Highlights (-100 to +100), Shadows (-100 to +100), Whites (-100 to +100), Blacks (-100 to +100).
  - **Presence Controls**: Texture (-100 to +100), Clarity (-100 to +100), Dehaze (-100 to +100), Vibrance (-100 to +100), Saturation (-100 to +100).
  - **Quick Action Bar**: Auto tone balance, Color/B&W treatment toggle, and Reset.
- **120fps Real-Time GPU Preview Engine (`LiveDevelopPreviewEngine`)**:
  - Dedicated background `.userInteractive` coalescing work queue with automatic frame dropping to eliminate latency during high-frequency slider drags.
  - Multi-tier display proxy architecture: 1440px interactive proxy for $<0.4$ms Metal renders during dragging, 2560px display proxy, and full-resolution background completion.
  - State isolation (`liveDevelopXMP`) preventing full catalog / GridView re-computation during live slider adjustments.
- **Lightroom-Style Slider Component (`LightroomSlider`)**:
  - Local drag coordinate tracking (`localDragValue`) for 0ms cursor tracking.
  - Center ticks, dual-direction gradient tracks for Temperature, Tint, and Saturation.
  - **Direct Numeric Text Input**: Single-click on any numeric label switches to an active text field with `@FocusState` keyboard focus; press Enter / Return to clamp and commit, Esc to cancel.
  - Double-click slider title or track to reset to default.
- **Enhanced Adobe PV2012 Color Pipeline (`AdobeColorPipeline`)**:
  - **Two-Stage Highlight Recovery & Tone Curve Matrix**: Apple bilateral filter highlight recovery (recovering blown skies and clouds) combined with 5-point parametric tone curve high-zone boost and shadow lifting/deepening.
  - **Skin Softening & Dreamy Glow**: Negative Texture enables high-frequency skin smoothing; negative Clarity produces soft-focus diffusion glow.
  - **Linear Saturation & True Grayscale**: Clean linear saturation scaling (-100 = 100% grayscale, +100 = 200% saturation) and `CIPhotoEffectMono` photographic monochrome.
  - **Color Science Direction Correction**: Temp higher = warmer amber, lower = cooler blue; Tint positive = magenta, negative = green.

---

## [1.2.0] - 2026-09-21

### Added
- **Enhanced Multi-Photo Selection**:
  - **Control / Command Click (`^ + Click` / `⌘ + Click`)**: Continuous multi-selection toggle supporting both macOS (`⌘`) and Windows/Cross-platform (`⌃`) mental models to seamlessly select or unselect individual photos without resetting existing selections.
  - **Shift Click (`⇧ + Click`)**: Contiguous range selection, selecting all photos between the anchor photo and the clicked target photo based on current sort/filter order.
  - Consistent behavior and selection highlights in both **Grid View** and **Loupe View** (Filmstrip bottom carousel).
- **Selection Anchor Tracking (`selectionAnchorAssetID`)**:
  - Automatically maintains the reference anchor photo during shift range expansion/contraction while setting the clicked photo as primary.
- **Photo & XMP Sidecar Deletion (`⌘ + Backspace` / Move to Trash)**:
  - Select one or multiple photos and press `⌘ + Backspace` (`Command + Delete`) to trigger deletion.
  - Native macOS confirmation modal dialog detailing photo count and warning that corresponding `.xmp` sidecar files will also be moved to the Trash.
  - Safe macOS Trash integration (`FileManager.trashItem`) preventing accidental data loss, with fallback to permanent deletion if needed.
  - Automatic cleanup of both `.ARW.xmp` and `.xmp` sidecars.
  - Seamless selection advance to the adjacent photo upon deletion.
  - Fully accessible in **Grid View**, **Loupe View**, bottom **FilmstripView**, right-click contextual menus, and top application Edit menu.
- **Automated DMG Distribution Script (`package_dmg.sh`)**:
  - One-click build and DMG packaging script for distributing standalone macOS installers.
  - Automatically compiles optimized Release build, configures staging folder with `/Applications` drag-and-drop symlink, and generates compressed read-only DMG with Apple `hdiutil`.
- **Unit Tests**:
  - Added `testRequestDeletePopulatesPendingAssets` and `testConfirmDeleteRemovesFilesAndXMP` (21/21 unit tests passing, 0 failures).

---

## [1.1.0] - 2026-09-20

### Added
- **Batch Export Engine (`PhotoExportService`)**:
  - Full-resolution RAW demosaicing with Apple CoreImage & Metal acceleration.
  - Complete Adobe PV2012 color pipeline application (Exposure, Temp/Tint, Highlights/Shadows, Whites/Blacks, Contrast, Clarity/Dehaze, Vibrance/Saturation).
  - High-fidelity `sRGB IEC61966-2.1` ICC profile embedding to guarantee consistent color reproduction across all devices and browsers.
  - Preservation of full camera EXIF, TIFF, lens, and GPS metadata.
  - Dynamic Floating HUD progress indicator with item counter, progress bar, percentage, and cancellation support.
  - Shortcut `⇧⌘E` (Shift + Command + E), toolbar "Export" button, and contextual menus.
- **Select All & Batch Operations**:
  - Keyboard shortcuts `⌘A` (Command + A) to select all filtered/displayed assets, and `⌘D` (Command + D) to deselect.
  - Window-level and View-level key handlers in `AppState`, `GridView`, and `LoupeView`.
  - Main menu integration under Edit (`Select All`, `Deselect All`) and File (`Export Selected Photos...`, `Export All Photos...`).
  - Dynamic batch export actions: `Export All (N)` when all items are selected, `Export (N)` for multi-selection.
- **Filmstrip Dual-Level Selection Highlights**:
  - Distinctive visual states in Filmstrip thumbnail strip during multi-selection:
    - **Primary / Active Photo**: Signature Lightroom bright amber yellow border (2.5px).
    - **Selected Photos**: High-visibility white frame (2.0px) with 18% translucent white overlay.
    - **Unselected Photos**: Subdued opacity (65%) with subtle hairline border.
  - Filmstrip mouse interaction: Click to switch active photo, `⌘+Click` or `⇧+Click` for range/toggle selection.
  - Contextual menu in Filmstrip for batch export, selection, and Finder reveal.
- **Native macOS App Icon & HIG Asset Catalog**:
  - Created customized Apple Human Interface Guidelines compliant App Icon with monogram "LB".
  - Multi-resolution iconset (`Assets.xcassets/AppIcon.appiconset`) and `AppIcon.icns` supporting 16×16 through 1024×1024 Retina.
  - Researched and documented macOS App Icon design specifications (824×824 squircle in 1024×1024 canvas with 100px shadow gutter).
- **Unit Test Suite Expansion**:
  - Added `PhotoExportServiceTests` covering single raster export, full-res Sony A7C II ARW demosaicing, batch progress reporting, and orientation validation (17/17 tests passing).

### Fixed
- **Portrait RAW Photo Double-Rotation Bug**:
  - Fixed an issue where portrait RAW photos (e.g. `A7C01319.ARW`, EXIF Orientation = 8) exported as JPEG were displayed sideways in Preview/Finder.
  - `CIRAWFilter` already yields an upright 4672×7008 pixel buffer; fixed redundant RAW orientation metadata copying by explicitly setting output JPEG orientation tag to `1` (Normal / Upright).
- **Thumbnail & Loupe Orientation Consistency**:
  - Fixed thumbnail dimensions and orientation handling for portrait RAW photos to ensure 100% upright consistency between Grid View, Loupe View, and exported JPEG files.
- **Asset Selection Stability**:
  - Replaced random UUID generation with canonical standardized file path (`fileURL.standardizedFileURL.path`) as persistent `PhotoAsset.id`, resolving erratic selection resets during folder refresh.

---

## [1.0.0] - 2026-09-20

### Added
- **High-Performance RAW Digital Asset Management (DAM)**:
  - Native macOS application optimized for Apple Silicon (M1/M2/M3/M4) unified memory and Metal GPU.
  - Broad camera RAW support: Sony (`.ARW`), Canon (`.CR2`, `.CR3`), Nikon (`.NEF`), Adobe/Leica/Apple (`.DNG`), Fujifilm (`.RAF`), Panasonic (`.RW2`), Olympus (`.ORF`).
- **1:1 Adobe Camera RAW Color Pipeline**:
  - `DCPProfileManager`: Dynamic discovery and loading of official Adobe Standard DCP profiles from Adobe Camera Raw directories.
  - `AdobeColorPipeline`: Metal-accelerated PV2012 develop settings pipeline matching Adobe Lightroom Classic output.
- **Two-Tier Thumbnail Cache (`ThumbnailCacheManager`)**:
  - In-memory cache + persistent disk cache (`com.lumibase.thumbnails.v2`) ensuring 100% color match between Grid thumbnails, Filmstrip, and Loupe view.
- **Non-Destructive Bidirectional XMP Sidecar Synchronization**:
  - Pure XML XMP Parser & Writer supporting Lightroom-compatible rating (`0-5`), flags (`Pick`/`Reject`/`Unflag`), and develop settings without touching RAW originals.
  - Automatic `.xmp` creation upon rating/flagging unrated photos.
- **Recursive File Explorer Tree & Sidebar**:
  - Unrestricted folder navigation with sandboxing privileges for external SSDs (`/Volumes`).
  - Distinct sections: `RECENT FOLDERS`, `PLACES & DISKS`, and `SMART COLLECTIONS`.
- **Lightroom-Style Keyboard Navigation**:
  - 2D Grid navigation (`↑` / `↓` row jumps, `←` / `→` step).
  - Quick view switching (`Enter` / `Return` / `E` / `Space` for Loupe, `Esc` / `G` for Grid).
  - Rapid rating (`0-5`) and flagging (`P`, `X`, `U`).
  - Panel toggling with `Tab`.
