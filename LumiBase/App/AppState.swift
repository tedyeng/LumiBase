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
    
    // Export State
    @Published public var isExporting: Bool = false
    @Published public var exportProgressFraction: Double = 0.0
    @Published public var exportCurrentFilename: String = ""
    @Published public var exportCompletedCount: Int = 0
    @Published public var exportTotalCount: Int = 0
    @Published public var exportErrorMessage: String?
    private var exportTask: Task<Void, Never>?
    
    // Watcher & Keyboard Monitor
    private let directoryWatcher = DirectoryWatcher()
    private var keyMonitor: Any?
    
    public init() {
        directoryWatcher.onChange = { [weak self] in
            Task { @MainActor in
                self?.refreshCurrentFolder()
            }
        }
        
        setupKeyMonitor()
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
        // Only ignore keyboard shortcuts if user is currently typing in an active text input field
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView, responder.isFieldEditor {
            return false
        }
        
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // 0. Modifier Key Combinations (e.g. ⇧⌘E for Export)
        if flags.contains([.command, .shift]) {
            let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
            if lower == "e" {
                self.exportSelectedPhotos()
                return true
            }
        }
        
        // Command combinations (⌘A for Select All, ⌘D for Deselect All)
        if flags.contains(.command) && !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control) {
            let lower = (event.charactersIgnoringModifiers ?? "").lowercased()
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
        let keyCode = event.keyCode
        
        // 1. Star Ratings (0 - 5)
        if ["0", "1", "2", "3", "4", "5"].contains(chars) {
            if let r = Int(chars) {
                self.setRating(r)
                return true
            }
        }
        
        // 2. Flags, Navigation & Layout Shortcuts
        switch chars {
        case "p", "P": self.setFlag(.pick); return true
        case "x", "X": self.setFlag(.reject); return true
        case "u", "U": self.setFlag(.unflagged); return true
        case "g", "G": self.viewMode = .grid; return true
        case "e", "E": self.viewMode = .loupe; return true
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
            return displayedAssets.first
        }
        return allAssets.first { $0.id == id }
    }
    
    public var selectedAssets: [PhotoAsset] {
        displayedAssets.filter { selectedAssetIDs.contains($0.id) }
    }
    
    // MARK: - Folder Actions
    
    public func openFolder(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        currentFolderURL = url
        selectedAssetIDs.removeAll()
        primarySelectedAssetID = nil
        
        directoryWatcher.startWatching(url: url)
        
        // 1. Instant shallow list of assets
        let quickAssets = FolderScanner.quickScan(url: url)
        if !quickAssets.isEmpty {
            self.allAssets = quickAssets
            if let first = self.displayedAssets.first {
                self.primarySelectedAssetID = first.id
                self.selectedAssetIDs = [first.id]
            }
        }
        
        Task {
            isScanning = true
            scanProgressMessage = "Scanning \(url.lastPathComponent)..."
            
            let assets = await FolderScanner.scanDirectory(url: url)
            self.allAssets = assets
            
            let sorted = self.displayedAssets
            if self.primarySelectedAssetID == nil || !assets.contains(where: { $0.id == self.primarySelectedAssetID }) {
                if let first = sorted.first {
                    self.primarySelectedAssetID = first.id
                    self.selectedAssetIDs = [first.id]
                }
            }
            
            self.isScanning = false
        }
    }
    
    public func refreshCurrentFolder() {
        guard let url = currentFolderURL, !isScanning else { return }
        
        Task {
            let assets = await FolderScanner.scanDirectory(url: url)
            self.allAssets = assets
            
            // Maintain primary selection if still exists
            if let primaryID = primarySelectedAssetID, !assets.contains(where: { $0.id == primaryID }) {
                let sorted = self.displayedAssets
                self.primarySelectedAssetID = sorted.first?.id
                if let first = sorted.first {
                    self.selectedAssetIDs = [first.id]
                } else {
                    self.selectedAssetIDs.removeAll()
                }
            }
        }
    }
    
    // MARK: - Selection Actions
    
    public func selectAsset(_ asset: PhotoAsset, multiSelect: Bool = false) {
        if multiSelect {
            if selectedAssetIDs.contains(asset.id) {
                selectedAssetIDs.remove(asset.id)
                if primarySelectedAssetID == asset.id {
                    primarySelectedAssetID = selectedAssetIDs.first
                }
            } else {
                selectedAssetIDs.insert(asset.id)
                primarySelectedAssetID = asset.id
            }
        } else {
            selectedAssetIDs = [asset.id]
            primarySelectedAssetID = asset.id
        }
    }
    
    public func selectAll() {
        let assets = displayedAssets
        selectedAssetIDs = Set(assets.map { $0.id })
        if primarySelectedAssetID == nil || !selectedAssetIDs.contains(primarySelectedAssetID!) {
            primarySelectedAssetID = assets.first?.id
        }
    }
    
    public func deselectAll() {
        selectedAssetIDs.removeAll()
        primarySelectedAssetID = nil
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
    
    private func updateAsset(_ updated: PhotoAsset) {
        if let index = allAssets.firstIndex(where: { $0.id == updated.id }) {
            allAssets[index] = updated
        }
    }
    
    private func syncXMP(for asset: PhotoAsset) {
        let xmpURL = asset.sidecarXMPURL
        Task.detached(priority: .utility) {
            try? XMPWriter.write(metadata: asset.xmp, to: xmpURL, originalFilename: asset.filename)
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
}

