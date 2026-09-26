import SwiftUI
import Combine

public enum ViewMode: String, CaseIterable {
    case grid = "Grid"
    case loupe = "Loupe"
}

@MainActor
public final class AppState: ObservableObject {
    // Current directory & assets
    @Published public var currentFolderURL: URL?
    @Published public var allAssets: [PhotoAsset] = []
    @Published public var isScanning: Bool = false
    @Published public var scanProgressMessage: String = ""
    
    // Selection state
    @Published public var selectedAssetIDs: Set<String> = []
    @Published public var primarySelectedAssetID: String?
    @Published public var selectionAnchorAssetID: String?
    
    // Live Develop State (Isolated for ultra-fast 120fps live slider interaction)
    @Published public var liveDevelopAssetID: String?
    @Published public var liveDevelopXMP: XMPMetadata?
    
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
    
    // View state
    @Published public var viewMode: ViewMode = .grid
    @Published public var thumbnailSize: CGFloat = 220
    @Published public var gridColumnsCount: Int = 4
    @Published public var filterCriteria: FilterCriteria = FilterCriteria()
    @Published public var sortOrder: AssetSortOrder = .captureDateAscending
    
    // Sidebar foldout state
    @Published public var isLeftSidebarVisible: Bool = true
    @Published public var isRightInspectorVisible: Bool = true
    @Published public var isFilmstripVisible: Bool = true
    
    // Native Highlights (Accepted-B) toggle - default false
    @Published public var isNativeHighlightsEnabled: Bool = UserDefaults.standard.bool(forKey: "isNativeHighlightsEnabled") {
        didSet {
            UserDefaults.standard.set(isNativeHighlightsEnabled, forKey: "isNativeHighlightsEnabled")
            NativeHighlightsService.isEnabled = isNativeHighlightsEnabled
            RAWImageLoader.shared.clearCache()
            if let primaryID = primarySelectedAssetID {
                updateDevelopSettings(for: primaryID, isDragging: false) { _ in }
            }
        }
    }
    
    // Export State
    @Published public var isExporting: Bool = false
    @Published public var exportProgressFraction: Double = 0.0
    @Published public var exportCurrentFilename: String = ""
    @Published public var exportCompletedCount: Int = 0
    @Published public var exportTotalCount: Int = 0
    @Published public var exportErrorMessage: String?
    private var exportTask: Task<Void, Never>?
    
    // Deletion State
    @Published public var showDeleteConfirmation: Bool = false
    @Published public var pendingDeleteAssets: [PhotoAsset] = []
    
    // Watcher & Keyboard Monitor
    private let directoryWatcher = DirectoryWatcher()
    private var folderScanTask: Task<Void, Never>?
    private var folderScanGeneration: UInt64 = 0
    private var scopedFolderURL: URL?
    private var ownsScopedFolderAccess = false
    private var keyMonitor: Any?
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
                self?.refreshCurrentFolder()
            }
        }
        
        setupKeyMonitor()
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
    
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleGlobalKeyEvent(event) {
                return nil
            }
            return event
        }
    }
    
    public func handleGlobalKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        
        // Only ignore keyboard shortcuts if user is currently typing in an active text input field
        if let responder = NSApp.keyWindow?.firstResponder, (responder is NSTextView || responder is NSTextField) {
            // If user presses Escape while in a text input field, dismiss focus and consume event
            if keyCode == 53 { // Escape
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(nil)
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
    public var displayedAssets: [PhotoAsset] {
        let filtered = allAssets.filter { filterCriteria.matches(asset: $0) }
        return sortAssets(filtered, by: sortOrder)
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
        displayedAssets.filter { selectedAssetIDs.contains($0.id) }
    }
    
    // MARK: - Folder Actions
    
    public func openFolder(url: URL) {
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
        allAssets = assets
        let sorted = displayedAssets
        if primarySelectedAssetID == nil || !assets.contains(where: { $0.id == primarySelectedAssetID }) {
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
    
    // MARK: - Selection Actions
    
    /// Selects an asset with support for:
    /// - Normal click: select single asset, reset previous selection, and set as primary & anchor
    /// - Toggle (Control/Command + click): toggle individual asset in selection without resetting others
    /// - Range (Shift + click): select contiguous range of assets between anchor and clicked asset
    public func selectAsset(_ asset: PhotoAsset, isToggle: Bool = false, isRange: Bool = false) {
        // Resign any active text input focus (like search bar) when user clicks to select photos
        if let responder = NSApp.keyWindow?.firstResponder, (responder is NSTextView || responder is NSTextField) {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
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
    
    /// Updates develop/Basic settings on the primary selected asset with instant isolated live update and debounced catalog commit
    public func updateDevelopSettings(for assetID: String? = nil, isDragging: Bool = false, mutate: (inout XMPMetadata) -> Void) {
        let targetID = assetID ?? primarySelectedAssetID
        guard let id = targetID, let index = allAssets.firstIndex(where: { $0.id == id }) else { return }
        
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
            
            if applyAutoSync {
                for otherID in otherSelectedIDs {
                    if let otherIdx = allAssets.firstIndex(where: { $0.id == otherID }) {
                        mutate(&allAssets[otherIdx].xmp)
                        debouncedSyncXMP(for: allAssets[otherIdx])
                    }
                }
            }
        } else {
            // Dragging in progress: debounce catalog mutation by 200ms so main thread is 100% free for 120fps slider UI
            if applyAutoSync {
                for otherID in otherSelectedIDs {
                    if let otherIdx = allAssets.firstIndex(where: { $0.id == otherID }) {
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
            guard !Task.isCancelled, let self = self else { return }
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
        
        for targetID in targets {
            guard let idx = allAssets.firstIndex(where: { $0.id == targetID }) else { continue }
            var targetXMP = allAssets[idx].xmp
            options.apply(from: sourceXMP, to: &targetXMP)
            allAssets[idx].xmp = targetXMP
            if liveDevelopAssetID == targetID {
                liveDevelopXMP = targetXMP
            }
            debouncedSyncXMP(for: allAssets[idx])
        }
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
    
    /// Resets develop settings to default zero for the asset
    public func resetDevelopSettings(for assetID: String? = nil) {
        updateDevelopSettings(for: assetID, isDragging: false) { xmp in
            xmp.resetDevelopSettings()
        }
    }
    
    /// Auto calculates tone (balanced exposure and highlights/shadows recovery)
    public func autoTone(for assetID: String? = nil) {
        updateDevelopSettings(for: assetID, isDragging: false) { xmp in
            xmp.exposure2012 = 0.20
            xmp.contrast2012 = 15
            xmp.highlights2012 = -30
            xmp.shadows2012 = 35
            xmp.whites2012 = 10
            xmp.blacks2012 = -10
            xmp.vibrance = 15
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
    
    // MARK: - Crop & Rotate Actions
    
    /// Toggles between Edit (Develop adjustments) and Crop & Straighten mode
    public func toggleCropMode() {
        if let responder = NSApp.keyWindow?.firstResponder, (responder is NSTextView || responder is NSTextField) {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        if activeDevelopTool == .crop {
            activeDevelopTool = .edit
        } else {
            activeDevelopTool = .crop
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
        if let index = allAssets.firstIndex(where: { $0.id == updated.id }) {
            allAssets[index] = updated
            if liveDevelopAssetID == updated.id {
                liveDevelopXMP = updated.xmp
            }
        }
    }
    
    private func syncXMP(for asset: PhotoAsset) {
        let xmpURL = asset.sidecarXMPURL
        Task.detached(priority: .utility) {
            try? XMPWriter.write(metadata: asset.xmp, to: xmpURL, originalFilename: asset.filename)
        }
    }
    
    private func debouncedSyncXMP(for asset: PhotoAsset) {
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
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.title = "Export \(assets.count) Photo\(assets.count > 1 ? "s" : "") to JPEG"
        
        if let current = currentFolderURL {
            panel.directoryURL = current
        }
        
        if panel.runModal() == .OK, let targetDir = panel.url {
            startExport(assets: assets, outputDirectory: targetDir)
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
        
        guard !items.isEmpty else { return }
        self.pendingDeleteAssets = items
        self.showDeleteConfirmation = true
    }
    
    /// Confirms and executes moving pending photo(s) and any associated XMP sidecar(s) to macOS Trash
    public func confirmDeletePendingPhotos() {
        guard !pendingDeleteAssets.isEmpty else { return }
        
        let deletedAssets = pendingDeleteAssets
        let currentList = displayedAssets
        let deletedIDs = Set(deletedAssets.map { $0.id })
        
        // Calculate the next candidate asset to select after deletion
        var nextAssetToSelect: PhotoAsset?
        if let primaryID = primarySelectedAssetID,
           let currentIndex = currentList.firstIndex(where: { $0.id == primaryID }) {
            // Try subsequent items first
            if let nextItem = currentList[(currentIndex + 1)...].first(where: { !deletedIDs.contains($0.id) }) {
                nextAssetToSelect = nextItem
            } else if let prevItem = currentList[..<currentIndex].reversed().first(where: { !deletedIDs.contains($0.id) }) {
                nextAssetToSelect = prevItem
            }
        }
        
        let fileManager = FileManager.default
        
        for asset in deletedAssets {
            for fileURL in asset.allAssociatedURLs {
                if fileManager.fileExists(atPath: fileURL.path) {
                    do {
                        try fileManager.trashItem(at: fileURL, resultingItemURL: nil)
                    } catch {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
            }
        }
        
        // 3. Update memory assets list
        self.allAssets.removeAll { deletedIDs.contains($0.id) }
        self.selectedAssetIDs.subtract(deletedIDs)
        
        // 4. Update selection
        if let next = nextAssetToSelect {
            self.primarySelectedAssetID = next.id
            self.selectionAnchorAssetID = next.id
            if self.selectedAssetIDs.isEmpty {
                self.selectedAssetIDs = [next.id]
            }
        } else if let firstRemaining = self.displayedAssets.first {
            self.primarySelectedAssetID = firstRemaining.id
            self.selectionAnchorAssetID = firstRemaining.id
            self.selectedAssetIDs = [firstRemaining.id]
        } else {
            self.primarySelectedAssetID = nil
            self.selectionAnchorAssetID = nil
            self.selectedAssetIDs.removeAll()
        }
        
        self.pendingDeleteAssets = []
        self.showDeleteConfirmation = false
    }
    
    public func cancelDelete() {
        self.pendingDeleteAssets = []
        self.showDeleteConfirmation = false
    }
}
