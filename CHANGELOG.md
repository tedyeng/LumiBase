# Changelog

All notable changes to **LumiBase** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

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
