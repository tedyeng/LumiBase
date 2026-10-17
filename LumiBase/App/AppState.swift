import SwiftUI
import Combine

public enum ViewMode: String, CaseIterable {
    case grid = "Grid"
    case loupe = "Loupe"
}

/// Fence is installed on MainActor before queuing Trash; every sidecar write checks
/// it on the same serial file queue. An already-running write finishes before Trash.
private final class FileMutationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>(), paths = Set<String>()
    func block(_ assets: [PhotoAsset]) {
        lock.lock(); defer { lock.unlock() }
        for asset in assets {
            ids.insert(asset.id)
            for url in [asset.fileURL] + asset.companionURLs {
                ids.insert(url.standardizedFileURL.path)
                paths.insert(url.appendingPathExtension("xmp").standardizedFileURL.path)
                paths.insert(url.deletingPathExtension().appendingPathExtension("xmp").standardizedFileURL.path)
            }
        }
    }
    func permits(_ id: String, _ url: URL? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !ids.contains(id) && (url == nil || !paths.contains(url!.standardizedFileURL.path))
    }
}

public enum WorkspaceMode: String, CaseIterable { case library = "Library", develop = "Develop" }
public enum DisplayPreviewPolicy { case cameraJPEG, accurate }

@MainActor
public final class AppState: ObservableObject {
    @Published public var workspaceMode: WorkspaceMode = .library {
        didSet {
            guard oldValue != workspaceMode else { return }
            if let id = liveDevelopAssetID, let live = liveDevelopXMP,
               let index = allAssets.firstIndex(where: { $0.id == id }) {
                allAssets[index].xmp = live
                debouncedSyncXMP(for: allAssets[index])
            }
            liveCommitTask?.cancel(); liveDevelopAssetID = nil; liveDevelopXMP = nil
            activeDevelopTool = .edit; comparisonMode = .off; isBeforeToggled = false
            invalidateDisplaySource()
        }
    }
    @Published public private(set) var displaySourceRevision: UInt64 = 0
    public func previewPolicy(for asset: PhotoAsset, native: Bool) -> DisplayPreviewPolicy {
        workspaceMode == .library && !asset.xmp.hasDevelopEdits ? .cameraJPEG : .accurate
    }
    public func previewLabel(for asset: PhotoAsset, native: Bool) -> String {
        if previewPolicy(for: asset, native: native) == .cameraJPEG {
            return native ? "Native JPEG 100%" : "Camera preview (JPEG)"
        }
        return workspaceMode == .library ? "Edited preview • accurate + edits" : "Develop • accurate RAW + edits"
    }
    public let displayHistogram = DisplayHistogramState()
    let previewSharpness = PreviewSharpnessState()
    private func refreshPreviewSharpness() {
        guard PerformanceSettings.shared.sharpnessEnabled, var asset = primarySelectedAsset,
              let frame = displayedBitmap, frame.assetID == asset.id,
              frame.sourceRevision == displaySourceRevision else { return }
        if liveDevelopAssetID == asset.id, let liveDevelopXMP { asset.xmp = liveDevelopXMP }
        guard !isBeforeToggled, comparisonMode == .off else { previewSharpness.clear(); return }
        let processed = previewPolicy(for: asset, native: true) == .accurate
        guard !processed || frame.accurate else { previewSharpness.clear(); return }
        // Frame publication is only a scheduling signal, never the score's pixels.
        // Native ROI publications therefore cannot masquerade as a full-frame input.
        previewSharpness.submit(asset: asset, revision: displaySourceRevision, processed: processed)
    }
    @Published public var isHistogramEnabled: Bool = UserDefaults.standard.bool(forKey: "displayHistogramEnabled") {
        didSet {
            UserDefaults.standard.set(isHistogramEnabled, forKey: "displayHistogramEnabled")
            displayHistogram.enabled = isHistogramEnabled
            if isHistogramEnabled, let frame = displayedBitmap, frame.assetID == primarySelectedAssetID, (workspaceMode == .library && frame.allowPreviewHistogram) || frame.accurate {
                displayHistogram.submit(frame.image, label: frame.label)
            }
        }
    }
    struct DisplayedBitmap {
        let assetID: String
        let image: NSImage
        let label: String
        let sourceRevision: UInt64
        let accurate: Bool
        let allowPreviewHistogram: Bool
        let readyUptime: TimeInterval
        let scorePreview: Bool
    }
    @Published private(set) var displayedBitmap: DisplayedBitmap?
    public func publishDisplayedBitmap(_ image: NSImage?, assetID: String?, label: String, accurate: Bool = true, allowPreviewHistogram: Bool = true, scorePreview: Bool = true) {
        guard let assetID, assetID == primarySelectedAssetID, let image else {
            displayedBitmap = nil; displayHistogram.clear(); return
        }
        displayedBitmap = DisplayedBitmap(assetID: assetID, image: image, label: label, sourceRevision: displaySourceRevision, accurate: accurate, allowPreviewHistogram: allowPreviewHistogram, readyUptime: ProcessInfo.processInfo.systemUptime, scorePreview: scorePreview)
        refreshPreviewSharpness()
        displayHistogram.enabled = isHistogramEnabled
        if (workspaceMode == .library && allowPreviewHistogram) || accurate { displayHistogram.submit(image, label: label) }
        else { displayHistogram.clear() }
    }
    private func invalidateDisplaySource() {
        previewSharpness.clear()
        displaySourceRevision &+= 1
        displayedBitmap = nil; displayHistogram.clear()
        RAWImageLoader.shared.clearCache()
        InspectionReadyFrameStore.shared.clearAll()
        LiveDevelopPreviewEngine.shared.cancelPending()
        Task { await ProcessedROICacheService.shared.invalidateForRenderingPolicyChange() }
    }
    // Current directory & assets
    @Published public var currentFolderURL: URL?
    @Published public var allAssets: [PhotoAsset] = [] {
        didSet {
            invalidateCollection()
            let old = oldValue.first { $0.id == primarySelectedAssetID }
            let new = allAssets.first { $0.id == primarySelectedAssetID }
            if old?.xmp.thumbnailDevelopCacheIdentity != new?.xmp.thumbnailDevelopCacheIdentity || old?.dateModified != new?.dateModified || old?.fileSize != new?.fileSize || old?.companionURLs != new?.companionURLs {
                previewSharpness.clear()
            }
        }
    }
    @Published public var isScanning: Bool = false
    @Published public var scanProgressMessage: String = ""
    
    // Selection state
    @Published public var selectedAssetIDs: Set<String> = [] { didSet { selectedAssetsCache = nil } }
    @Published public var primarySelectedAssetID: String? {
        didSet { if oldValue != primarySelectedAssetID { displayedBitmap = nil; displayHistogram.clear(); previewSharpness.clear() } }
    }
    @Published public var selectionAnchorAssetID: String?
    
    // Live Develop State (Isolated for ultra-fast 120fps live slider interaction)
    @Published public var liveDevelopAssetID: String?
    @Published public var liveDevelopXMP: XMPMetadata? {
        didSet {
            invalidateCollection()
            previewSharpness.clear()
        }
    }
    
    // Sync & Copy/Paste Develop State (Lightroom Classic Workflow)
    @Published public var isAutoSyncEnabled: Bool = false
    @Published public var showSyncDialog: Bool = false
    @Published public var showCopySettingsDialog: Bool = false
    @Published public var copiedDevelopSettings: XMPMetadata? = nil
    @Published public var copiedSyncOptions: DevelopSyncOptions = .default
    @Published public var lastSyncOptions: DevelopSyncOptions = .default
    
    // Active Develop Tool Mode (Edit vs Crop & Rotate)
    @Published public var activeDevelopTool: DevelopToolMode = .edit
    @Published public var cropAspectRatioPreset: CropAspectRatioPreset = .original
    @Published public var isCropAspectLocked: Bool = true
    @Published public var cropOverlayStyle: CropOverlayStyle = .grid
    
    // Before / After Comparison State (Lightroom Classic Workflow)
    @Published public var comparisonMode: ComparisonMode = .off { didSet { previewSharpness.clear() } }
    @Published public var isBeforeToggled: Bool = false { didSet { previewSharpness.clear() } }
    @Published public var splitPosition: CGFloat = 0.5
    
    // View state
    @Published public var viewMode: ViewMode = .grid {
        didSet {
            guard oldValue != viewMode else { return }
            previewSharpness.clear()
            DispatchQueue.main.async {
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
    @Published public var thumbnailSize: CGFloat = 220
    @Published public var gridColumnsCount: Int = 4
    @Published public var filterCriteria: FilterCriteria = FilterCriteria() { didSet { invalidateCollection() } }
    @Published public var sortOrder: AssetSortOrder = .captureDateAscending { didSet { invalidateCollection() } }
    
    // Sidebar foldout state
    @Published public var isLeftSidebarVisible: Bool = true
    @Published public var isRightInspectorVisible: Bool = true
    @Published public var isFilmstripVisible: Bool = true
    
    // Native Highlights (Accepted-B) toggle - default true
    @Published public private(set) var highlightsRenderRevision: UInt64 = 0
    @Published public var isNativeHighlightsEnabled: Bool = (UserDefaults.standard.object(forKey: "isNativeHighlightsEnabled") as? Bool) ?? true {
        didSet {
            guard oldValue != isNativeHighlightsEnabled else { return }
            UserDefaults.standard.set(isNativeHighlightsEnabled, forKey: "isNativeHighlightsEnabled")
            NativeHighlightsService.isEnabled = isNativeHighlightsEnabled
            previewSharpness.clear()
            RAWImageLoader.shared.clearCache()
            InspectionReadyFrameStore.shared.clearAll()
            Task { await ProcessedROICacheService.shared.invalidateForRenderingPolicyChange() }
            // This is a rendering policy, not a photo edit. Trigger the Loupe
            // without modifying live XMP, batch Auto Sync, or XMP sidecars.
            highlightsRenderRevision &+= 1
        }
    }
    
    // Export State
    @Published public var isExporting: Bool = false
    @Published public var exportProgressFraction: Double = 0.0
    @Published public var exportCurrentFilename: String = ""
    @Published public var exportCompletedCount: Int = 0
    @Published public var exportTotalCount: Int = 0
    @Published public var exportErrorMessage: String?
    @Published public var xmpSaveError: String?
    private var exportTask: Task<Void, Never>?
    
    // Deletion State
    @Published public var showDeleteConfirmation: Bool = false
    @Published public var pendingDeleteAssets: [PhotoAsset] = []
    @Published public var deleteErrorMessage: String?
    @Published public private(set) var deletingAssetIDs: Set<String> = [] { didSet { invalidateCollection() } }
    private var trashTasks: [UUID: Task<Void, Never>] = [:]
    private var trashedAssetIDs: Set<String> = [] { didSet { invalidateCollection() } }
    private var trashGroupMemberIDs: Set<String> = []
    private var failedTrashAssets: [String: PhotoAsset] = [:]
    private let fileMutationFence = FileMutationFence()
    public func waitForTrashCompletion() async {
        while let task = trashTasks.values.first { await task.value }
    }
    func enqueueFileWorkForTesting(_ work: @escaping @Sendable () -> Void) { xmpWriteQueue.async(execute: work) }
    
    // Watcher & Keyboard Monitor
    private let directoryWatcher = DirectoryWatcher()
    private var folderScanTask: Task<Void, Never>?
    private var folderRefreshDebounceTask: Task<Void, Never>?
    private var folderScanGeneration: UInt64 = 0
    private var scopedFolderURL: URL?
    private var ownsScopedFolderAccess = false
    private var keyMonitor: Any?
    private var photoFocusMonitor: Any?
    var photoBrowserHasKeyboardFocus = false
    let photoKeyboardSurfaces = NSHashTable<NSView>.weakObjects()
    private var previewSubscriptions = Set<AnyCancellable>()
    private var priorPreviewAssetIDs: [String] = []
    private var priorPreviewSelectionID: String?
    private var priorPreviewViewMode: ViewMode = .grid
    private var previewRefreshGeneration: UInt64 = 0
    private var previewRefreshTask: Task<Void, Never>?
    private let previewPreloader: PreviewPreloader
    private let quickFolderScan: @Sendable (URL) -> [PhotoAsset]
    private let fullFolderScan: @Sendable (URL) async -> [PhotoAsset]
    struct PreviewSnapshotForTesting { let assetIDs: [String]; let selectedID: String? }
    var previewSnapshotForTesting = PreviewSnapshotForTesting(assetIDs: [], selectedID: nil)

    public init(preloader: PreviewPreloader = .shared,
                quickFolderScan: @escaping @Sendable (URL) -> [PhotoAsset] = { url in
                    FolderScanner.quickScan(url: url)
                },
                fullFolderScan: @escaping @Sendable (URL) async -> [PhotoAsset] = { url in
                    await FolderScanner.scanDirectory(url: url)
                }) {
        self.previewPreloader = preloader
        self.quickFolderScan = quickFolderScan
        self.fullFolderScan = fullFolderScan
        directoryWatcher.onChange = { [weak self] in
            Task { @MainActor in
                self?.scheduleFolderRefresh()
            }
        }
        
        setupKeyMonitor()
        PerformanceSettings.shared.$sharpnessEnabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.previewSharpness.clear() }
            else { Task { @MainActor [weak self] in await Task.yield(); self?.refreshPreviewSharpness() } }
        }.store(in: &previewSubscriptions)
        PerformanceSettings.shared.$highlightPreviewQuality.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.highlightsRenderRevision &+= 1
            }
        }.store(in: &previewSubscriptions)
        Publishers.MergeMany(
            $allAssets.map { _ in () }.eraseToAnyPublisher(),
            $primarySelectedAssetID.map { _ in () }.eraseToAnyPublisher(),
            $filterCriteria.map { _ in () }.eraseToAnyPublisher(),
            $sortOrder.map { _ in () }.eraseToAnyPublisher(),
            $currentFolderURL.map { _ in () }.eraseToAnyPublisher(),
            $liveDevelopXMP.map { _ in () }.eraseToAnyPublisher(),
            $viewMode.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.schedulePreviewRefresh() }
        .store(in: &previewSubscriptions)
    }

    deinit {
        let preloader = previewPreloader
        Task { await preloader.cancelAndClear() }
        folderScanTask?.cancel()
        folderRefreshDebounceTask?.cancel()
        if ownsScopedFolderAccess, let scopedFolderURL {
            scopedFolderURL.stopAccessingSecurityScopedResource()
        }
    }

    private func schedulePreviewRefresh() {
        previewRefreshGeneration &+= 1
        let generation = previewRefreshGeneration
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.previewRefreshGeneration == generation else { return }
            let assets = self.displayedAssets
            let selectedID = self.primarySelectedAssetID
            let ids = assets.map(\.id)
            let oldIndex = self.priorPreviewSelectionID.flatMap { self.priorPreviewAssetIDs.firstIndex(of: $0) }
            let newIndex = selectedID.flatMap { id in ids.firstIndex(of: id) }
            let direction: PreviewTravelDirection = self.priorPreviewAssetIDs == ids && oldIndex != nil && newIndex != nil && oldIndex != newIndex
                ? (newIndex! > oldIndex! ? .forward : .backward) : .stationary
            self.priorPreviewAssetIDs = ids
            let shouldArmForeground = self.viewMode == .loupe &&
                (selectedID != self.priorPreviewSelectionID || self.priorPreviewViewMode != .loupe)
            self.priorPreviewSelectionID = selectedID
            self.priorPreviewViewMode = self.viewMode
            self.previewSnapshotForTesting = PreviewSnapshotForTesting(assetIDs: ids, selectedID: selectedID)
            if shouldArmForeground, let selectedID {
                await self.previewPreloader.armForegroundSelection(selectedID)
            } else if self.viewMode != .loupe || selectedID == nil {
                await self.previewPreloader.foregroundSelectionEnded()
            }
            await self.previewPreloader.update(assets: assets, selectedID: selectedID, direction: direction)
        }
    }
    
    // Mouse focus ownership is scoped to the image/grid/filmstrip, not the inspector.
    func updatePhotoKeyboardFocus(_ event: NSEvent) {
        photoBrowserHasKeyboardFocus = photoKeyboardSurfaces.allObjects.contains { view in
            guard let window = event.window, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }

    private func setupKeyMonitor() {
        photoFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.updatePhotoKeyboardFocus(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Local monitors are app-wide: Settings and other windows own their keys.
            guard let window = event.window, window.isKeyWindow,
                  self.photoKeyboardSurfaces.allObjects.contains(where: { $0.window === window }),
                  window.attachedSheet == nil else { return event }
            if self.handleGlobalKeyEvent(event) {
                return nil
            }
            return event
        }
    }
    
    public func handleGlobalKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        // The confirmation alert owns Return/Escape and its own key equivalents.
        if showDeleteConfirmation { return false }
        
        // Only ignore keyboard shortcuts if user is currently typing in an active text input field
        if let responder = (event.window ?? NSApplication.shared.keyWindow)?.firstResponder, (responder is NSTextView || responder is NSTextField) {
            // If user presses Escape while in a text input field, dismiss focus and consume event
            if keyCode == 53 { // Escape
                DispatchQueue.main.async {
                    NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                }
                return true
            }
            // If user presses Cmd+F, refocus search
            if flags.contains(.command) {
                let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
                if lower == "f" {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFocusSearch"), object: nil)
                    return true
                }
            }
            return false
        }
        
        // Plain macOS Backspace uses the same confirmation as Command+Delete.
        if keyCode == 51 && !flags.contains(.command) && !flags.contains(.control)
            && !flags.contains(.option) && !flags.contains(.shift) && photoBrowserHasKeyboardFocus {
            let window = event.window ?? NSApplication.shared.keyWindow
            guard window?.attachedSheet == nil, !showSyncDialog, !showCopySettingsDialog,
                  !(window?.firstResponder is NSControl) else { return false }
            requestDeleteSelectedPhotos()
            return true
        }

        // macOS Fn+Delete emits forward delete (117), usually with .function.
        // Keep it out of editable text and do not accept other modifier chords.
        if keyCode == 117 && !flags.contains(.command) && !flags.contains(.control)
            && !flags.contains(.option) && !flags.contains(.shift) {
            requestDeleteSelectedPhotos()
            return true
        }

        // 0. Modifier Key Combinations (Export, Sync, Copy/Paste Develop Settings)
        if flags.contains([.command, .shift, .option]) {
            let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
            if lower == "s" {
                self.toggleAutoSync()
                return true
            }
        }
        
        if flags.contains([.command, .shift]) && !flags.contains(.option) {
            let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
            if lower == "e" {
                self.exportSelectedPhotos()
                return true
            }
            if lower == "s" {
                if self.selectedAssetIDs.count > 1 {
                    self.showSyncDialog = true
                    return true
                }
            }
            if lower == "c" {
                if self.primarySelectedAsset != nil {
                    self.showCopySettingsDialog = true
                    return true
                }
            }
            if lower == "v" {
                self.pasteDevelopSettings()
                return true
            }
            if lower == "r" {
                self.reloadXMP()
                return true
            }
        }
        
        if flags.contains([.command, .option]) && !flags.contains(.shift) {
            let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
            if lower == "v" {
                self.pasteDevelopSettings()
                return true
            }
            if lower == "s" {
                self.toggleAutoSync()
                return true
            }
        }
        
        // Command combinations (⌘F for Search, ⌘A for Select All, ⌘D for Deselect All, ⌘⌫ for Delete)
        if flags.contains(.command) && !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control) {
            if event.keyCode == 51 { // 51 is Backspace / Delete
                self.requestDeleteSelectedPhotos()
                return true
            }
            let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
            if lower == "f" {
                NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFocusSearch"), object: nil)
                return true
            }
            if lower == "a" {
                self.selectAll()
                return true
            }
            if lower == "d" {
                self.deselectAll()
                return true
            }
        }
        
        // Ignore single-character navigation/rating if Command or Control is held
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }
        
        let chars = event.charactersIgnoringModifiers ?? ""
        
        // 1. Star Ratings (0 - 5, [ decrease, ] increase)
        if ["0", "1", "2", "3", "4", "5"].contains(chars) {
            if let r = Int(chars) {
                self.setRating(r)
                return true
            }
        }
        if chars == "]" {
            self.increaseRating()
            return true
        }
        if chars == "[" {
            self.decreaseRating()
            return true
        }
        
        // 2. Crop, Flags, Navigation & Layout Shortcuts
        if chars == "r" || chars == "R" {
            self.toggleCropMode()
            return true
        }
        
        if self.activeDevelopTool == .crop {
            if chars == "o" || chars == "O" {
                self.cycleCropOverlayStyle()
                return true
            }
            if chars == "x" || chars == "X" {
                self.flipCropOrientation()
                return true
            }
            if keyCode == 36 || keyCode == 76 || keyCode == 53 { // Enter / Return / Esc exits crop
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.activeDevelopTool = .edit
                }
                return true
            }
        }
        
        switch chars {
        case "p", "P": self.setFlag(.pick); return true
        case "x", "X": self.setFlag(.reject); return true
        case "u", "U": self.setFlag(.unflagged); return true
        case "g", "G": self.viewMode = .grid; return true
        case "e", "E": self.viewMode = .loupe; return true
        case "z", "Z":
            NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
            return true
        case "i", "I":
            NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleInfoOverlay"), object: nil)
            return true
        case "\\":
            self.toggleBeforeAfter()
            return true
        case "y", "Y":
            self.cycleComparisonMode(forward: !flags.contains(.shift))
            return true
        case " ":
            self.viewMode = (self.viewMode == .grid) ? .loupe : .grid
            return true
        case "\t":
            withAnimation {
                let show = !self.isLeftSidebarVisible
                self.isLeftSidebarVisible = show
                self.isRightInspectorVisible = show
            }
            return true
        default:
            break
        }
        
        // 3. Arrow Keys & Navigation
        switch keyCode {
        case 123: // Left Arrow
            self.selectPreviousPhoto()
            return true
        case 124: // Right Arrow
            self.selectNextPhoto()
            return true
        case 126: // Up Arrow
            if self.viewMode == .grid {
                self.selectUpInGrid()
            } else {
                self.selectPreviousPhoto()
            }
            return true
        case 125: // Down Arrow
            if self.viewMode == .grid {
                self.selectDownInGrid()
            } else {
                self.selectNextPhoto()
            }
            return true
        case 36, 76: // Enter / Return (main keyboard + numpad)
            if self.viewMode == .grid {
                self.viewMode = .loupe
                return true
            }
            return false
        case 53: // Escape
            if self.viewMode == .loupe {
                self.viewMode = .grid
                return true
            }
            self.deselectAll()
            return true
        case 98: // F7 (Toggle Left Sidebar)
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isLeftSidebarVisible.toggle()
            }
            return true
        case 100: // F8 (Toggle Right Inspector)
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isRightInspectorVisible.toggle()
            }
            return true
        default:
            break
        }
        
        return false
    }
    
    // MARK: - Computed Properties
    
    /// Filtered and sorted assets displayed in Grid / Loupe / Filmstrip
    private var displayedAssetsCache: [PhotoAsset]?
    private var selectedAssetsCache: [PhotoAsset]?
    private func invalidateCollection() {
        displayedAssetsCache = nil
        selectedAssetsCache = nil
    }
    public var displayedAssets: [PhotoAsset] {
        if let cached = displayedAssetsCache { return cached }
        let filtered = allAssets.filter { !deletingAssetIDs.contains($0.id) && !trashedAssetIDs.contains($0.id) && filterCriteria.matches(asset: $0) }
        let sorted = sortAssets(filtered, by: sortOrder)
        let result = sorted.map { asset -> PhotoAsset in
            if liveDevelopAssetID == asset.id, let live = liveDevelopXMP {
                var a = asset
                a.xmp = live
                return a
            }
            return asset
        }
        displayedAssetsCache = result
        return result
    }
    
    /// Only scroll to the explicit active photo when it is still in the visible collection.
    /// Do not substitute the first photo or another member of a multi-selection.
    var gridScrollTargetID: String? {
        guard let id = primarySelectedAssetID,
              displayedAssets.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// One-based position of the active photo in the current filtered, sorted collection.
    public var photoPositionLabel: String {
        let assets = displayedAssets
        guard let id = primarySelectedAssetID,
              let index = assets.firstIndex(where: { $0.id == id }) else {
            return "\(assets.count) photos"
        }
        return "\(index + 1) / \(assets.count) photos"
    }

    public var primarySelectedAsset: PhotoAsset? {
        guard let id = primarySelectedAssetID else {
            guard var first = displayedAssets.first else { return nil }
            if liveDevelopAssetID == first.id, let live = liveDevelopXMP {
                first.xmp = live
            }
            return first
        }
        guard var asset = allAssets.first(where: { $0.id == id }) else { return nil }
        if liveDevelopAssetID == id, let live = liveDevelopXMP {
            asset.xmp = live
        }
        return asset
    }
    
    public var selectedAssets: [PhotoAsset] {
        if let cached = selectedAssetsCache { return cached }
        let result = displayedAssets.filter { selectedAssetIDs.contains($0.id) }.map { asset -> PhotoAsset in
            if liveDevelopAssetID == asset.id, let live = liveDevelopXMP {
                var a = asset
                a.xmp = live
                return a
            }
            return asset
        }
        selectedAssetsCache = result
        return result
    }
    
    // MARK: - Folder Actions
    
    public func openFolder(url: URL) {
        folderRefreshDebounceTask?.cancel()
        folderScanGeneration &+= 1
        let generation = folderScanGeneration
        folderScanTask?.cancel()
        retainCurrentFolderAccess(for: url)
        currentFolderURL = url
        allAssets = []
        selectedAssetIDs.removeAll()
        primarySelectedAssetID = nil
        selectionAnchorAssetID = nil
        isScanning = true
        scanProgressMessage = "Scanning \(url.lastPathComponent)..."
        
        directoryWatcher.startWatching(url: url)
        
        let quickFolderScan = self.quickFolderScan
        let fullFolderScan = self.fullFolderScan
        folderScanTask = Task { @MainActor [weak self] in
            let scanHasScope = url.startAccessingSecurityScopedResource()
            defer {
                if scanHasScope { url.stopAccessingSecurityScopedResource() }
            }
            let quickTask = Task.detached(priority: .userInitiated) { quickFolderScan(url) }
            let quickAssets = await withTaskCancellationHandler {
                await quickTask.value
            } onCancel: {
                quickTask.cancel()
            }
            guard let self, !Task.isCancelled, self.folderScanGeneration == generation else { return }
            if !quickAssets.isEmpty {
                self.publishFolderAssets(quickAssets)
            }

            let assets = await fullFolderScan(url)
            guard !Task.isCancelled, self.folderScanGeneration == generation else { return }
            self.publishFolderAssets(assets)
            self.isScanning = false
            self.folderScanTask = nil
        }
    }

    private func retainCurrentFolderAccess(for url: URL) {
        guard scopedFolderURL?.standardizedFileURL != url.standardizedFileURL else { return }
        if ownsScopedFolderAccess, let scopedFolderURL {
            scopedFolderURL.stopAccessingSecurityScopedResource()
        }
        ownsScopedFolderAccess = url.startAccessingSecurityScopedResource()
        scopedFolderURL = url
    }

    private func publishFolderAssets(_ assets: [PhotoAsset]) {
        var safe = assets.filter { !trashGroupMemberIDs.contains($0.id) && !trashedAssetIDs.contains($0.id) && !deletingAssetIDs.contains($0.id) }
        let retained = allAssets.filter { deletingAssetIDs.contains($0.id) }
        safe.append(contentsOf: retained)
        for failed in failedTrashAssets.values where (currentFolderURL == nil || failed.fileURL.deletingLastPathComponent().standardizedFileURL.path == currentFolderURL?.standardizedFileURL.path) && !safe.contains(where: { $0.id == failed.id }) { safe.append(failed) }
        allAssets = safe
        let sorted = displayedAssets
        if primarySelectedAssetID == nil || !safe.contains(where: { $0.id == primarySelectedAssetID }) {
            if let first = sorted.first {
                primarySelectedAssetID = first.id
                selectionAnchorAssetID = first.id
                selectedAssetIDs = [first.id]
            } else {
                primarySelectedAssetID = nil
                selectionAnchorAssetID = nil
                selectedAssetIDs.removeAll()
            }
        }
    }
    
    /// Coalesce sidecar writes so a batch sync scans/publishes the folder once.
    func scheduleFolderRefresh() {
        guard let url = currentFolderURL else { return }
        folderRefreshDebounceTask?.cancel()
        folderRefreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self,
                  self.currentFolderURL?.standardizedFileURL == url.standardizedFileURL else { return }
            self.folderRefreshDebounceTask = nil
            self.refreshCurrentFolder()
        }
    }

    public func refreshCurrentFolder() {
        guard let url = currentFolderURL, !isScanning else { return }

        folderScanGeneration &+= 1
        let generation = folderScanGeneration
        folderScanTask?.cancel()
        let fullFolderScan = self.fullFolderScan
        folderScanTask = Task { @MainActor [weak self] in
            let scanHasScope = url.startAccessingSecurityScopedResource()
            defer {
                if scanHasScope { url.stopAccessingSecurityScopedResource() }
            }
            let assets = await fullFolderScan(url)
            guard let self, !Task.isCancelled, self.folderScanGeneration == generation,
                  self.currentFolderURL?.standardizedFileURL == url.standardizedFileURL else { return }
            self.publishFolderAssets(assets)
            self.folderScanTask = nil
        }
    }
    
    /// Reloads XMP metadata from disk for specified assets, or for the current selection / folder
    public func reloadXMP(for assetIDs: Set<String>? = nil) {
        let targetIDs: Set<String>
        if let assetIDs = assetIDs, !assetIDs.isEmpty {
            targetIDs = assetIDs
        } else if !selectedAssetIDs.isEmpty {
            targetIDs = selectedAssetIDs
        } else if let primary = primarySelectedAssetID {
            targetIDs = [primary]
        } else {
            refreshCurrentFolder()
            return
        }
        
        let scoped = currentFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if scoped { currentFolderURL?.stopAccessingSecurityScopedResource() }
        }
        
        for id in targetIDs {
            guard fileMutationFence.permits(id),
                  let idx = allAssets.firstIndex(where: { $0.id == id }) else { continue }
            
            xmpDebounceTasks[id]?.cancel()
            xmpDebounceTasks.removeValue(forKey: id)
            
            let asset = allAssets[idx]
            let freshXMP = XMPParser.loadXMP(for: asset.fileURL)
            allAssets[idx].xmp = freshXMP
            
            if liveDevelopAssetID == id {
                liveCommitTask?.cancel()
                liveDevelopXMP = freshXMP
            }
        }
        
        invalidateCollection()
        invalidateDisplaySource()
        highlightsRenderRevision &+= 1
        schedulePreviewRefresh()
    }
    
    // MARK: - Selection Actions
    
    /// Selects an asset with support for:
    /// - Normal click: select single asset, reset previous selection, and set as primary & anchor
    /// - Toggle (Control/Command + click): toggle individual asset in selection without resetting others
    /// - Range (Shift + click): select contiguous range of assets between anchor and clicked asset
    public func selectAsset(_ asset: PhotoAsset, isToggle: Bool = false, isRange: Bool = false) {
        guard !deletingAssetIDs.contains(asset.id), !trashedAssetIDs.contains(asset.id) else { return }
        photoBrowserHasKeyboardFocus = true
        // Resign any active text input focus (like search bar) when user clicks to select photos
        if let responder = NSApplication.shared.keyWindow?.firstResponder, (responder is NSTextView || responder is NSTextField) {
            DispatchQueue.main.async {
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
        }
        
        let currentList = displayedAssets
        
        // If primary selection changes, commit any pending live develop XMP and reset live cache
        if primarySelectedAssetID != asset.id {
            if let liveID = liveDevelopAssetID, let live = liveDevelopXMP, let index = allAssets.firstIndex(where: { $0.id == liveID }) {
                allAssets[index].xmp = live
                debouncedSyncXMP(for: allAssets[index])
            }
            liveDevelopAssetID = nil
            liveDevelopXMP = nil
            liveCommitTask?.cancel()
            isBeforeToggled = false
        }
        
        if isRange {
            // Determine starting point (anchor)
            let anchorID = selectionAnchorAssetID ?? primarySelectedAssetID ?? asset.id
            guard let anchorIndex = currentList.firstIndex(where: { $0.id == anchorID }),
                  let targetIndex = currentList.firstIndex(where: { $0.id == asset.id }) else {
                // Fallback to single select
                selectedAssetIDs = [asset.id]
                primarySelectedAssetID = asset.id
                selectionAnchorAssetID = asset.id
                return
            }
            
            let startIndex = min(anchorIndex, targetIndex)
            let endIndex = max(anchorIndex, targetIndex)
            let rangeIDs = currentList[startIndex...endIndex].map { $0.id }
            
            selectedAssetIDs = Set(rangeIDs)
            primarySelectedAssetID = asset.id
            // Note: In standard macOS / Lightroom, anchor remains at the original starting point during shift-click
            if selectionAnchorAssetID == nil {
                selectionAnchorAssetID = anchorID
            }
        } else if isToggle {
            if selectedAssetIDs.contains(asset.id) {
                selectedAssetIDs.remove(asset.id)
                if primarySelectedAssetID == asset.id {
                    primarySelectedAssetID = selectedAssetIDs.first
                }
            } else {
                selectedAssetIDs.insert(asset.id)
                primarySelectedAssetID = asset.id
            }
            selectionAnchorAssetID = asset.id
        } else {
            selectedAssetIDs = [asset.id]
            primarySelectedAssetID = asset.id
            selectionAnchorAssetID = asset.id
        }
    }
    
    /// Backward-compatibility overload for simple multiSelect boolean
    public func selectAsset(_ asset: PhotoAsset, multiSelect: Bool) {
        selectAsset(asset, isToggle: multiSelect, isRange: false)
    }
    
    public func selectAll() {
        let assets = displayedAssets
        selectedAssetIDs = Set(assets.map { $0.id })
        if primarySelectedAssetID == nil || !selectedAssetIDs.contains(primarySelectedAssetID!) {
            primarySelectedAssetID = assets.first?.id
        }
        if selectionAnchorAssetID == nil {
            selectionAnchorAssetID = primarySelectedAssetID
        }
    }
    
    public func deselectAll() {
        selectedAssetIDs.removeAll()
        primarySelectedAssetID = nil
        selectionAnchorAssetID = nil
    }
    
    public func selectNextPhoto() {
        selectStepPhoto(offset: 1)
    }
    
    public func selectPreviousPhoto() {
        selectStepPhoto(offset: -1)
    }
    
    public func selectUpInGrid() {
        let cols = max(1, gridColumnsCount)
        selectStepPhoto(offset: -cols)
    }
    
    public func selectDownInGrid() {
        let cols = max(1, gridColumnsCount)
        selectStepPhoto(offset: cols)
    }
    
    public func selectStepPhoto(offset: Int) {
        let currentList = displayedAssets
        guard !currentList.isEmpty else { return }
        
        guard let primary = primarySelectedAssetID,
              let currentIndex = currentList.firstIndex(where: { $0.id == primary }) else {
            if let first = currentList.first {
                selectAsset(first)
            }
            return
        }
        
        let newIndex = max(0, min(currentList.count - 1, currentIndex + offset))
        selectAsset(currentList[newIndex])
    }
    
    // MARK: - Rating & XMP Actions (Keyboard & UI Driven)
    
    public func setRating(_ rating: Int) {
        let targetAssets = selectedAssets.isEmpty ? (primarySelectedAsset != nil ? [primarySelectedAsset!] : []) : selectedAssets
        guard !targetAssets.isEmpty else { return }
        
        for asset in targetAssets {
            var updated = asset
            updated.xmp.rating = max(0, min(5, rating))
            updateAsset(updated)
            syncXMP(for: updated)
        }
    }
    
    public func increaseRating() {
        let targetAssets = selectedAssets.isEmpty ? (primarySelectedAsset != nil ? [primarySelectedAsset!] : []) : selectedAssets
        guard !targetAssets.isEmpty else { return }
        
        for asset in targetAssets {
            var updated = asset
            let newRating = min(5, updated.xmp.rating + 1)
            if newRating != updated.xmp.rating {
                updated.xmp.rating = newRating
                updateAsset(updated)
                syncXMP(for: updated)
            }
        }
    }
    
    public func decreaseRating() {
        let targetAssets = selectedAssets.isEmpty ? (primarySelectedAsset != nil ? [primarySelectedAsset!] : []) : selectedAssets
        guard !targetAssets.isEmpty else { return }
        
        for asset in targetAssets {
            var updated = asset
            let newRating = max(0, updated.xmp.rating - 1)
            if newRating != updated.xmp.rating {
                updated.xmp.rating = newRating
                updateAsset(updated)
                syncXMP(for: updated)
            }
        }
    }
    
    public func setColorLabel(_ label: ColorLabel) {
        let targetAssets = selectedAssets.isEmpty ? (primarySelectedAsset != nil ? [primarySelectedAsset!] : []) : selectedAssets
        guard !targetAssets.isEmpty else { return }
        
        for asset in targetAssets {
            var updated = asset
            updated.xmp.colorLabel = (updated.xmp.colorLabel == label) ? .none : label
            updateAsset(updated)
            syncXMP(for: updated)
        }
    }
    
    public func setFlag(_ flag: FlagStatus) {
        let targetAssets = selectedAssets.isEmpty ? (primarySelectedAsset != nil ? [primarySelectedAsset!] : []) : selectedAssets
        guard !targetAssets.isEmpty else { return }
        
        for asset in targetAssets {
            var updated = asset
            updated.xmp.flag = (updated.xmp.flag == flag) ? .unflagged : flag
            updateAsset(updated)
            syncXMP(for: updated)
        }
    }
    
    public func updateMetadata(keywords: [String], title: String?, caption: String?) {
        guard var asset = primarySelectedAsset else { return }
        asset.xmp.keywords = keywords
        asset.xmp.title = title
        asset.xmp.caption = caption
        updateAsset(asset)
        syncXMP(for: asset)
    }
    
    // MARK: - Develop / Basic Adjustments
    
    private var xmpDebounceTasks: [String: Task<Void, Never>] = [:]
    private var liveCommitTask: Task<Void, Never>?
    private let xmpWriteQueue = DispatchQueue(label: "com.lumibase.xmp-writes", qos: .utility)

    /// A photo's explicit sidecar choice overrides the legacy app preference.
    /// Missing flags keep their prior behavior until the user chooses per photo.
    public func advancedRAWHighlightRecovery(for assetID: String) -> Bool {
        let xmp = (liveDevelopAssetID == assetID ? liveDevelopXMP : nil)
            ?? allAssets.first(where: { $0.id == assetID })?.xmp
        return NativeHighlightsService.isAdvancedEnabled(for: xmp)
    }

    /// This setting belongs to the selected photo, not UserDefaults or Auto Sync.
    public func setAdvancedRAWHighlightRecovery(_ enabled: Bool, for assetID: String) {
        guard fileMutationFence.permits(assetID) else { return }
        guard let index = allAssets.firstIndex(where: { $0.id == assetID }) else { return }
        var xmp = (liveDevelopAssetID == assetID ? liveDevelopXMP : nil) ?? allAssets[index].xmp
        guard xmp.advancedRAWHighlightRecovery != enabled else { return }
        xmp.advancedRAWHighlightRecovery = enabled
        let asset = allAssets[index]
        // Preserve the discrete durable-save behavior when idle. During Trash,
        // next-photo edits must queue rather than synchronously wait on MainActor.
        xmpDebounceTasks[assetID]?.cancel()
        xmpDebounceTasks.removeValue(forKey: assetID)
        if deletingAssetIDs.isEmpty {
            do {
                try xmpWriteQueue.sync {
                    try XMPWriter.write(metadata: xmp, to: asset.sidecarXMPURL, originalFilename: asset.filename)
                }
            } catch {
                xmpSaveError = "Could not save \(asset.filename): \(error.localizedDescription)"
                return
            }
        } else {
            let metadata = xmp, sidecarURL = asset.sidecarXMPURL, fence = fileMutationFence
            xmpWriteQueue.async { [weak self] in
                guard fence.permits(assetID, sidecarURL) else { return }
                do {
                    try XMPWriter.write(metadata: metadata, to: sidecarURL, originalFilename: asset.filename)
                } catch {
                    let message = "Could not save \(asset.filename): \(error.localizedDescription)"
                    Task { @MainActor [weak self] in self?.xmpSaveError = message }
                }
            }
        }
        xmpSaveError = nil
        liveCommitTask?.cancel()
        liveDevelopAssetID = assetID
        liveDevelopXMP = xmp
        allAssets[index].xmp = xmp
        RAWImageLoader.shared.clearCache()
        InspectionReadyFrameStore.shared.clearAll()
        Task { await ProcessedROICacheService.shared.invalidateForRenderingPolicyChange() }
        highlightsRenderRevision &+= 1
    }
    
    /// Updates develop/Basic settings on the primary selected asset with instant isolated live update and debounced catalog commit
    public func updateDevelopSettings(for assetID: String? = nil, isDragging: Bool = false, mutate: (inout XMPMetadata) -> Void) {
        if workspaceMode != .develop { workspaceMode = .develop }
        let targetID = assetID ?? primarySelectedAssetID
        guard let id = targetID, fileMutationFence.permits(id), let index = allAssets.firstIndex(where: { $0.id == id }) else { return }
        
        var currentXMP = (liveDevelopAssetID == id && liveDevelopXMP != nil) ? liveDevelopXMP! : allAssets[index].xmp
        mutate(&currentXMP)
        
        self.liveDevelopAssetID = id
        self.liveDevelopXMP = currentXMP
        
        // Auto Sync: if active and multiple assets selected, also apply mutation to other selected assets
        let applyAutoSync = isAutoSyncEnabled && selectedAssetIDs.count > 1 && (targetID == nil || targetID == primarySelectedAssetID || selectedAssetIDs.contains(id))
        let otherSelectedIDs = applyAutoSync ? selectedAssetIDs.filter { $0 != id } : []
        
        if !isDragging {
            // Mouse released or discrete tap: commit immediately to allAssets
            liveCommitTask?.cancel()
            allAssets[index].xmp = currentXMP
            debouncedSyncXMP(for: allAssets[index])
            displaySourceRevision &+= 1
            
            if applyAutoSync {
                for otherID in otherSelectedIDs {
                    if fileMutationFence.permits(otherID), let otherIdx = allAssets.firstIndex(where: { $0.id == otherID }) {
                        mutate(&allAssets[otherIdx].xmp)
                        debouncedSyncXMP(for: allAssets[otherIdx])
                    }
                }
            }
        } else {
            // Dragging in progress: debounce catalog mutation by 200ms so main thread is 100% free for 120fps slider UI
            if applyAutoSync {
                for otherID in otherSelectedIDs {
                    if fileMutationFence.permits(otherID), let otherIdx = allAssets.firstIndex(where: { $0.id == otherID }) {
                        mutate(&allAssets[otherIdx].xmp)
                    }
                }
            }
            debouncedCommitLiveDevelop(assetID: id, index: index, autoSyncIDs: otherSelectedIDs)
        }
    }
    
    private func debouncedCommitLiveDevelop(assetID: String, index: Int, autoSyncIDs: [String] = []) {
        liveCommitTask?.cancel()
        liveCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard !Task.isCancelled, let self = self, self.fileMutationFence.permits(assetID) else { return }
            if self.liveDevelopAssetID == assetID, let live = self.liveDevelopXMP, index < self.allAssets.count, self.allAssets[index].id == assetID {
                self.allAssets[index].xmp = live
                self.debouncedSyncXMP(for: self.allAssets[index])
            }
            for otherID in autoSyncIDs {
                if let otherIdx = self.allAssets.firstIndex(where: { $0.id == otherID }) {
                    self.debouncedSyncXMP(for: self.allAssets[otherIdx])
                }
            }
        }
    }
    
    // MARK: - Synchronize & Copy/Paste Develop Settings (Lightroom Classic Workflow)
    
    public func toggleAutoSync() {
        isAutoSyncEnabled.toggle()
    }
    
    /// Synchronizes develop settings from the primary (or specified) asset to all other selected assets
    public func syncDevelopSettings(from sourceID: String? = nil, to targetIDs: Set<String>? = nil, options: DevelopSyncOptions = .default) {
        let srcID = sourceID ?? primarySelectedAssetID
        guard let validSourceID = srcID, let sourceAsset = allAssets.first(where: { $0.id == validSourceID }) else { return }
        
        let sourceXMP = (liveDevelopAssetID == validSourceID && liveDevelopXMP != nil) ? liveDevelopXMP! : sourceAsset.xmp
        let targets = targetIDs ?? selectedAssetIDs.filter { $0 != validSourceID }
        guard !targets.isEmpty else { return }
        
        var updatedAssets = allAssets
        let indices = Dictionary(uniqueKeysWithValues: updatedAssets.indices.map { (updatedAssets[$0].id, $0) })
        var changed: [PhotoAsset] = []
        var liveTargetXMP: XMPMetadata?
        for targetID in targets {
            guard fileMutationFence.permits(targetID) else { continue }
            guard let idx = indices[targetID] else { continue }
            var targetXMP = updatedAssets[idx].xmp
            options.apply(from: sourceXMP, to: &targetXMP)
            guard targetXMP != updatedAssets[idx].xmp else { continue }
            updatedAssets[idx].xmp = targetXMP
            changed.append(updatedAssets[idx])
            if liveDevelopAssetID == targetID { liveTargetXMP = targetXMP }
        }
        guard !changed.isEmpty else { return }
        allAssets = updatedAssets
        if let liveTargetXMP { liveDevelopXMP = liveTargetXMP }
        for asset in changed { debouncedSyncXMP(for: asset) }
    }
    
    /// Copies develop settings from the primary (or specified) asset with the given selective options
    public func copyDevelopSettings(from sourceID: String? = nil, options: DevelopSyncOptions = .default) {
        let srcID = sourceID ?? primarySelectedAssetID
        guard let validSourceID = srcID, let sourceAsset = allAssets.first(where: { $0.id == validSourceID }) else { return }
        
        let sourceXMP = (liveDevelopAssetID == validSourceID && liveDevelopXMP != nil) ? liveDevelopXMP! : sourceAsset.xmp
        self.copiedDevelopSettings = sourceXMP
        self.copiedSyncOptions = options
    }
    
    /// Pastes copied develop settings to selected assets (or primary asset if single selection)
    public func pasteDevelopSettings(to targetIDs: Set<String>? = nil) {
        guard let sourceXMP = copiedDevelopSettings else { return }
        let targets: Set<String>
        if let explicit = targetIDs, !explicit.isEmpty {
            targets = explicit
        } else if !selectedAssetIDs.isEmpty {
            targets = selectedAssetIDs
        } else if let primary = primarySelectedAssetID {
            targets = [primary]
        } else {
            return
        }
        
        for targetID in targets {
            guard fileMutationFence.permits(targetID) else { continue }
            guard let idx = allAssets.firstIndex(where: { $0.id == targetID }) else { continue }
            var targetXMP = allAssets[idx].xmp
            copiedSyncOptions.apply(from: sourceXMP, to: &targetXMP)
            allAssets[idx].xmp = targetXMP
            if liveDevelopAssetID == targetID {
                liveDevelopXMP = targetXMP
            }
            debouncedSyncXMP(for: allAssets[idx])
        }
    }
    
    private var autoToneTask: Task<Void, Never>?
    private var autoWBTask: Task<Void, Never>?

    /// Resets develop settings to default zero for the asset
    public func resetDevelopSettings(for assetID: String? = nil) {
        autoToneTask?.cancel()
        autoWBTask?.cancel()
        invalidateDisplaySource()
        updateDevelopSettings(for: assetID, isDragging: false) { xmp in
            xmp.resetDevelopSettings()
        }
    }
    
    /// Auto calculates tone using statistical percentile prediction modeled from Lightroom Classic PV2012
    public func autoTone(for assetID: String? = nil) {
        let targetID = assetID ?? primarySelectedAssetID
        guard let validID = targetID, let asset = allAssets.first(where: { $0.id == validID }) else { return }
        
        autoToneTask?.cancel()
        
        // 1. Fast synchronous path if base holder is already decoded in memory (e.g. active in Loupe/Develop view)
        if let interactive = RAWImageLoader.shared.cachedHolder(for: asset.fileURL)?.interactive {
            let result = AutoToneService.shared.estimateAutoTone(from: interactive)
            updateDevelopSettings(for: validID, isDragging: false) { xmp in
                xmp.exposure2012 = result.exposure
                xmp.contrast2012 = result.contrast
                xmp.highlights2012 = result.highlights
                xmp.shadows2012 = result.shadows
                xmp.whites2012 = result.whites
                xmp.blacks2012 = result.blacks
                xmp.vibrance = result.vibrance
                xmp.saturation = result.saturation
            }
            return
        }
        
        // 2. If asset file exists on disk, decode and apply statistical prediction in a single pass (no intermediate flash)
        if FileManager.default.fileExists(atPath: asset.fileURL.path) {
            autoToneTask = Task { [weak self] in
                let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: nil)
                guard !Task.isCancelled, let interactive = holder?.interactive else { return }
                let result = AutoToneService.shared.estimateAutoTone(from: interactive)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.updateDevelopSettings(for: validID, isDragging: false) { xmp in
                        xmp.exposure2012 = result.exposure
                        xmp.contrast2012 = result.contrast
                        xmp.highlights2012 = result.highlights
                        xmp.shadows2012 = result.shadows
                        xmp.whites2012 = result.whites
                        xmp.blacks2012 = result.blacks
                        xmp.vibrance = result.vibrance
                        xmp.saturation = result.saturation
                    }
                }
            }
            return
        }
        
        // 3. Fallback baseline when file does not exist on disk (e.g. synthetic unit tests)
        updateDevelopSettings(for: validID, isDragging: false) { xmp in
            xmp.exposure2012 = 0.20
            xmp.contrast2012 = 15
            xmp.highlights2012 = -30
            xmp.shadows2012 = 35
            xmp.whites2012 = 10
            xmp.blacks2012 = -10
            xmp.vibrance = 15
        }
    }
    
    /// Auto calculates white balance using Gray World with Lightroom mired offset
    public func autoWhiteBalance(for assetID: String? = nil) {
        let targetID = assetID ?? primarySelectedAssetID
        guard let validID = targetID, let asset = allAssets.first(where: { $0.id == validID }) else { return }
        
        autoWBTask?.cancel()
        
        // 1. Fast synchronous path if base holder is already decoded in memory
        if let interactive = RAWImageLoader.shared.cachedHolder(for: asset.fileURL)?.interactive {
            let result = AutoToneService.shared.estimateAutoWB(from: interactive)
            updateDevelopSettings(for: validID, isDragging: false) { xmp in
                xmp.temperature = result.temperature
                xmp.tint = result.tint
            }
            return
        }
        
        // 2. If asset file exists on disk, decode and apply statistical estimation in a single pass
        if FileManager.default.fileExists(atPath: asset.fileURL.path) {
            autoWBTask = Task { [weak self] in
                let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: nil)
                guard !Task.isCancelled, let interactive = holder?.interactive else { return }
                let result = AutoToneService.shared.estimateAutoWB(from: interactive)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.updateDevelopSettings(for: validID, isDragging: false) { xmp in
                        xmp.temperature = result.temperature
                        xmp.tint = result.tint
                    }
                }
            }
            return
        }
        
        // 3. Fallback baseline when file does not exist on disk
        updateDevelopSettings(for: validID, isDragging: false) { xmp in
            xmp.temperature = 5500
            xmp.tint = 10
        }
    }
    
    /// Toggles black & white mode
    public func toggleMonochrome(for assetID: String? = nil) {
        updateDevelopSettings(for: assetID, isDragging: false) { xmp in
            let isCurrentBW = (xmp.convertToGrayscale == true || xmp.saturation == -100)
            if isCurrentBW {
                xmp.convertToGrayscale = false
                if xmp.saturation == -100 {
                    xmp.saturation = 0
                }
            } else {
                xmp.convertToGrayscale = true
            }
        }
    }
    
    // MARK: - Before / After Comparison Actions
    
    /// Toggles single-image Before (As Shot) view with \ shortcut
    public func toggleBeforeAfter() {
        if workspaceMode != .develop { workspaceMode = .develop }
        if comparisonMode != .off {
            comparisonMode = .off
            isBeforeToggled = false
        } else {
            isBeforeToggled.toggle()
        }
    }
    
    /// Cycles through Before/After comparison modes (Off -> Split -> Side-by-Side -> Top/Bottom -> Off)
    public func cycleComparisonMode(forward: Bool = true) {
        if workspaceMode != .develop { workspaceMode = .develop }
        if activeDevelopTool == .crop {
            activeDevelopTool = .edit
        }
        isBeforeToggled = false
        let all = ComparisonMode.allCases
        guard let idx = all.firstIndex(of: comparisonMode) else {
            comparisonMode = .splitLeftRight
            return
        }
        if forward {
            let nextIdx = (idx + 1) % all.count
            comparisonMode = all[nextIdx]
        } else {
            let prevIdx = (idx - 1 + all.count) % all.count
            comparisonMode = all[prevIdx]
        }
    }
    
    // MARK: - Crop & Rotate Actions
    
    /// Toggles between Edit (Develop adjustments) and Crop & Straighten mode
    public func toggleCropMode() {
        if workspaceMode != .develop { workspaceMode = .develop }
        if let responder = NSApplication.shared.keyWindow?.firstResponder, (responder is NSTextView || responder is NSTextField) {
            DispatchQueue.main.async {
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
        }
        if activeDevelopTool == .crop {
            activeDevelopTool = .edit
        } else {
            activeDevelopTool = .crop
            comparisonMode = .off
            isBeforeToggled = false
            if viewMode == .grid {
                viewMode = .loupe
            }
        }
    }
    
    /// Updates normalized crop geometry with live preview and catalog persistence
    public func updateCropGeometry(_ geometry: CropGeometry, for assetID: String? = nil, isDragging: Bool = false) {
        updateDevelopSettings(for: assetID, isDragging: isDragging) { xmp in
            xmp.cropTop = geometry.top
            xmp.cropLeft = geometry.left
            xmp.cropBottom = geometry.bottom
            xmp.cropRight = geometry.right
            xmp.cropAngle = geometry.angle
        }
    }
    
    /// Updates straighten / rotation angle (-45° to +45°)
    public func updateCropAngle(_ angle: Double, for assetID: String? = nil, isDragging: Bool = false) {
        updateDevelopSettings(for: assetID, isDragging: isDragging) { xmp in
            xmp.cropAngle = max(-45.0, min(45.0, angle))
        }
    }
    
    /// Resets crop box to full uncropped photo and angle to 0°
    public func resetCrop(for assetID: String? = nil) {
        updateDevelopSettings(for: assetID, isDragging: false) { xmp in
            xmp.resetCrop()
        }
    }
    
    /// Flips crop frame orientation between portrait and landscape (X key)
    public func flipCropOrientation(for assetID: String? = nil) {
        let targetID = assetID ?? primarySelectedAssetID
        guard let id = targetID, let asset = allAssets.first(where: { $0.id == id }) else { return }
        let currentXMP = (liveDevelopAssetID == id && liveDevelopXMP != nil) ? liveDevelopXMP! : asset.xmp
        let g = currentXMP.cropGeometry
        
        let curW = g.widthFraction
        let curH = g.heightFraction
        let centerX = (g.left + g.right) / 2.0
        let centerY = (g.top + g.bottom) / 2.0
        
        let newW = min(1.0, curH)
        let newH = min(1.0, curW)
        
        let newLeft = max(0.0, min(1.0 - newW, centerX - newW / 2.0))
        let newTop = max(0.0, min(1.0 - newH, centerY - newH / 2.0))
        
        let newGeom = CropGeometry(
            top: newTop,
            left: newLeft,
            bottom: newTop + newH,
            right: newLeft + newW,
            angle: g.angle
        )
        updateCropGeometry(newGeom, for: targetID, isDragging: false)
    }
    
    /// Cycles crop overlay guide style between dynamic alignment Grid and Rule of Thirds (O key)
    public func cycleCropOverlayStyle() {
        cropOverlayStyle = (cropOverlayStyle == .grid) ? .thirds : .grid
    }
    
    /// Sets crop aspect ratio preset and adjusts crop geometry
    public func setCropPreset(_ preset: CropAspectRatioPreset, for assetID: String? = nil) {
        self.cropAspectRatioPreset = preset
        self.isCropAspectLocked = (preset != .custom)
        
        guard preset != .custom else { return }
        
        let targetID = assetID ?? primarySelectedAssetID
        guard let id = targetID, let asset = allAssets.first(where: { $0.id == id }) else { return }
        let currentXMP = (liveDevelopAssetID == id && liveDevelopXMP != nil) ? liveDevelopXMP! : asset.xmp
        let g = currentXMP.cropGeometry
        
        let rawW: CGFloat = 3.0
        let rawH: CGFloat = 2.0
        guard let ratio = preset.ratio(originalWidth: rawW, originalHeight: rawH) else { return }
        
        let curAspect = rawW / rawH
        let desiredFractionRatio = ratio / curAspect
        
        var w = g.widthFraction
        var h = w / desiredFractionRatio
        if h > 1.0 {
            h = 1.0
            w = h * desiredFractionRatio
        }
        
        let centerX = (g.left + g.right) / 2.0
        let centerY = (g.top + g.bottom) / 2.0
        
        let newLeft = max(0.0, min(1.0 - w, centerX - w / 2.0))
        let newTop = max(0.0, min(1.0 - h, centerY - h / 2.0))
        
        let newGeom = CropGeometry(
            top: newTop,
            left: newLeft,
            bottom: newTop + h,
            right: newLeft + w,
            angle: g.angle
        )
        updateCropGeometry(newGeom, for: targetID, isDragging: false)
    }
    
    private func updateAsset(_ updated: PhotoAsset) {
        guard fileMutationFence.permits(updated.id) else { return }
        if let index = allAssets.firstIndex(where: { $0.id == updated.id }) {
            allAssets[index] = updated
            if liveDevelopAssetID == updated.id {
                liveDevelopXMP = updated.xmp
            }
        }
    }
    
    private func syncXMP(for asset: PhotoAsset) {
        guard fileMutationFence.permits(asset.id) else { return }
        let xmpURL = asset.sidecarXMPURL
        let fence = fileMutationFence
        xmpWriteQueue.async {
            guard fence.permits(asset.id, xmpURL) else { return }
            try? XMPWriter.write(metadata: asset.xmp, to: xmpURL, originalFilename: asset.filename)
        }
    }
    
    private func debouncedSyncXMP(for asset: PhotoAsset) {
        guard fileMutationFence.permits(asset.id) else { return }
        let assetID = asset.id
        xmpDebounceTasks[assetID]?.cancel()
        
        xmpDebounceTasks[assetID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            self?.syncXMP(for: asset)
            self?.xmpDebounceTasks.removeValue(forKey: assetID)
        }
    }
    
    // MARK: - Helper Sorting
    
    private func sortAssets(_ assets: [PhotoAsset], by order: AssetSortOrder) -> [PhotoAsset] {
        switch order {
        case .captureDateDescending:
            return assets.sorted {
                ($0.cameraMetadata.captureDate ?? $0.dateCreated) > ($1.cameraMetadata.captureDate ?? $1.dateCreated)
            }
        case .captureDateAscending:
            return assets.sorted {
                ($0.cameraMetadata.captureDate ?? $0.dateCreated) < ($1.cameraMetadata.captureDate ?? $1.dateCreated)
            }
        case .filenameAscending:
            return assets.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .filenameDescending:
            return assets.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        case .ratingDescending:
            return assets.sorted { $0.xmp.rating > $1.xmp.rating }
        case .ratingAscending:
            return assets.sorted { $0.xmp.rating < $1.xmp.rating }
        case .fileSizeDescending:
            return assets.sorted { $0.fileSize > $1.fileSize }
        }
    }
    
    // MARK: - Photo Export Actions
    
    public func exportSelectedPhotos() {
        let targets = selectedAssets.isEmpty ? (primarySelectedAsset != nil ? [primarySelectedAsset!] : []) : selectedAssets
        guard !targets.isEmpty else { return }
        exportPhotos(assets: targets)
    }
    
    public func exportAllPhotos() {
        let targets = displayedAssets
        guard !targets.isEmpty else { return }
        exportPhotos(assets: targets)
    }
    
    public func exportPhotos(assets: [PhotoAsset]) {
        guard !assets.isEmpty, !isExporting else { return }
        
        let syncedAssets = assets.map { asset -> PhotoAsset in
            if liveDevelopAssetID == asset.id, let live = liveDevelopXMP {
                var a = asset
                a.xmp = live
                return a
            }
            return asset
        }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.title = "Export \(syncedAssets.count) Photo\(syncedAssets.count > 1 ? "s" : "") to JPEG"
        
        if let current = currentFolderURL {
            panel.directoryURL = current
        }
        
        if panel.runModal() == .OK, let targetDir = panel.url {
            startExport(assets: syncedAssets, outputDirectory: targetDir)
        }
    }
    
    public func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
    }
    
    private func startExport(assets: [PhotoAsset], outputDirectory: URL) {
        isExporting = true
        exportProgressFraction = 0.0
        exportCompletedCount = 0
        exportTotalCount = assets.count
        exportErrorMessage = nil
        exportCurrentFilename = assets.first?.filename ?? ""
        
        exportTask = Task { @MainActor [weak self] in
            do {
                _ = try await PhotoExportService.shared.exportBatch(
                    assets: assets,
                    to: outputDirectory,
                    quality: 0.95
                ) { progress in
                    Task { @MainActor in
                        self?.exportCompletedCount = progress.completed
                        self?.exportTotalCount = progress.total
                        self?.exportProgressFraction = progress.fractionCompleted
                        self?.exportCurrentFilename = progress.currentFilename
                    }
                }
                
                self?.isExporting = false
                self?.exportTask = nil
                // Reveal exported folder in Finder
                NSWorkspace.shared.activateFileViewerSelecting([outputDirectory])
            } catch {
                self?.isExporting = false
                self?.exportTask = nil
                if !(error is CancellationError) {
                    self?.exportErrorMessage = error.localizedDescription
                }
            }
        }
    }
    
    // MARK: - Photo Deletion Actions
    
    /// Requests deletion of selected photo(s) by populating `pendingDeleteAssets` and triggering confirmation modal
    public func requestDeleteSelectedPhotos(targets: [PhotoAsset]? = nil) {
        let items: [PhotoAsset]
        if let explicit = targets, !explicit.isEmpty {
            items = explicit
        } else if !selectedAssets.isEmpty {
            items = selectedAssets
        } else if let primary = primarySelectedAsset {
            items = [primary]
        } else {
            return
        }
        
        let available = items.filter { !deletingAssetIDs.contains($0.id) && !trashedAssetIDs.contains($0.id) }
        guard !available.isEmpty else { return }
        self.pendingDeleteAssets = available
        self.showDeleteConfirmation = true
    }
    
    /// Serial background, Trash-only group transaction. Associated-file moves are
    /// not atomic; on a failure the group is retained and moved paths are reported.
    public func confirmDeletePendingPhotos(fileManager: FileManager = .default) {
        let assets = pendingDeleteAssets.filter { !deletingAssetIDs.contains($0.id) }
        guard !assets.isEmpty else { return }
        let ids = Set(assets.map(\.id))
        let list = displayedAssets
        let index = primarySelectedAssetID.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
        let next = list.dropFirst(index + 1).first { !ids.contains($0.id) }
            ?? list.prefix(index).reversed().first { !ids.contains($0.id) }
        fileMutationFence.block(assets)
        trashGroupMemberIDs.formUnion(assets.flatMap { ([$0.fileURL] + $0.companionURLs).map { $0.standardizedFileURL.path } })
        deletingAssetIDs.formUnion(ids)
        for id in ids { xmpDebounceTasks[id]?.cancel(); xmpDebounceTasks.removeValue(forKey: id) }
        if let liveID = liveDevelopAssetID, !fileMutationFence.permits(liveID) {
            liveCommitTask?.cancel(); liveDevelopAssetID = nil; liveDevelopXMP = nil
        }
        invalidateDisplaySource()
        folderScanGeneration &+= 1; folderScanTask?.cancel(); folderScanTask = nil; isScanning = false
        folderRefreshDebounceTask?.cancel()
        pendingDeleteAssets = []; showDeleteConfirmation = false; deleteErrorMessage = nil
        selectedAssetIDs.subtract(ids)
        if primarySelectedAssetID.map(ids.contains) == true {
            primarySelectedAssetID = next?.id; selectionAnchorAssetID = next?.id
            if let next { selectedAssetIDs = [next.id] }
        }
        // Acquire separate leases before allowing folder navigation to drop its lease.
        let scopeCandidates = assets.map { $0.fileURL.deletingLastPathComponent() } + [currentFolderURL].compactMap { $0 }
        let scopes = Set(scopeCandidates).filter { $0.startAccessingSecurityScopedResource() }
        let queue = xmpWriteQueue
        let transactionID = UUID()
        nonisolated(unsafe) let fm = fileManager
        trashTasks[transactionID] = Task { @MainActor in
            let result: (Set<String>, [String]) = await withCheckedContinuation { continuation in
                queue.async {
                    defer { for url in scopes { url.stopAccessingSecurityScopedResource() } }
                    var succeeded = Set<String>(), errors: [String] = []
                    for asset in assets {
                        guard fm.fileExists(atPath: asset.fileURL.path) else {
                            errors.append("\(asset.filename): primary file unavailable or missing; group retained. No companions moved. Restore the primary or reconnect the volume before retrying.")
                            continue
                        }
                        var moved: [String] = [], failed = false
                        // Evaluate sidecars here, after any already-running XMP write.
                        for url in asset.allAssociatedURLs {
                            guard fm.fileExists(atPath: url.path) else { continue }
                            do {
                                try fm.trashItem(at: url, resultingItemURL: nil)
                                guard !fm.fileExists(atPath: url.path) else {
                                    throw NSError(domain: "LumiBase.Trash", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Trash returned but source still exists"])
                                }
                                moved.append(url.lastPathComponent)
                            } catch {
                                failed = true
                                errors.append("\(asset.filename): failed \(url.lastPathComponent): \(error.localizedDescription). Already moved: \(moved.isEmpty ? "none" : moved.joined(separator: ", "))")
                                break
                            }
                        }
                        if !failed { succeeded.insert(asset.id) }
                    }
                    continuation.resume(returning: (succeeded, errors))
                }
            }
            self.trashedAssetIDs.formUnion(result.0)
            self.deletingAssetIDs.subtract(ids)
            self.allAssets.removeAll { result.0.contains($0.id) }
            self.selectedAssetIDs.subtract(result.0)
            for asset in assets {
                if result.0.contains(asset.id) { self.failedTrashAssets.removeValue(forKey: asset.id) }
                else { self.failedTrashAssets[asset.id] = asset }
            }
            if !result.1.isEmpty {
                self.deleteErrorMessage = "Trash partially failed. Failed assets are retained; some related files may already be in Trash. Restore moved files in Finder before retrying. Sidecar writes for these groups stay isolated for this session.\n" + result.1.joined(separator: "\n")
            }
            // Never replace a user's newer selection. If no next photo existed,
            // restore the failed photo as an explicit recovery target.
            if self.primarySelectedAssetID == nil, let failed = assets.first(where: { !result.0.contains($0.id) }),
               self.allAssets.contains(where: { $0.id == failed.id }) {
                self.primarySelectedAssetID = failed.id; self.selectionAnchorAssetID = failed.id
                self.selectedAssetIDs = [failed.id]
            }
            self.trashTasks.removeValue(forKey: transactionID)
            self.scheduleFolderRefresh()
        }
    }

    public func cancelDelete() {
        self.pendingDeleteAssets = []
        self.showDeleteConfirmation = false
    }
}
