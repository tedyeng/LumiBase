import SwiftUI

/// Main Library Grid View displaying photo assets in a responsive grid
public struct GridView: View {
    @ObservedObject var appState: AppState
    
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: appState.thumbnailSize, maximum: appState.thumbnailSize + 50), spacing: 10)]
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if appState.displayedAssets.isEmpty {
                        emptyStateView
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 10) {
                            ForEach(appState.displayedAssets) { asset in
                                let isSelected = appState.selectedAssetIDs.contains(asset.id)
                                let isPrimary = appState.primarySelectedAssetID == asset.id
                                
                                PhotoGridItemView(
                                    asset: asset,
                                    isSelected: isSelected,
                                    isPrimary: isPrimary,
                                    size: appState.thumbnailSize,
                                    onSelect: { isToggle, isRange in
                                        appState.selectAsset(asset, isToggle: isToggle, isRange: isRange)
                                    },
                                    onDoubleClick: {
                                        appState.selectAsset(asset)
                                        appState.viewMode = .loupe
                                    },
                                    onRatingChange: { newRating in
                                        appState.selectAsset(asset)
                                        appState.setRating(newRating)
                                    },
                                    onFlagToggle: {
                                        appState.selectAsset(asset)
                                        let nextFlag: FlagStatus
                                        switch asset.xmp.flag {
                                        case .unflagged: nextFlag = .pick
                                        case .pick: nextFlag = .reject
                                        case .reject: nextFlag = .unflagged
                                        }
                                        appState.setFlag(nextFlag)
                                    }
                                )
                                .id(asset.id)
                                .contextMenu {
                                    gridContextMenu(for: asset)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
                .background(LightroomTheme.workspaceBackground)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    appState.selectPreviousPhoto()
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    appState.selectNextPhoto()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    appState.selectUpInGrid()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    appState.selectDownInGrid()
                    return .handled
                }
                .onKeyPress(.return) {
                    if appState.primarySelectedAssetID != nil {
                        appState.viewMode = .loupe
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(KeyEquivalent("a"), phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        appState.selectAll()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(KeyEquivalent("d"), phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        appState.deselectAll()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.delete, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        appState.requestDeleteSelectedPhotos()
                        return .handled
                    }
                    return .ignored
                }
                .contextMenu {
                    Button("Select All (⌘A)") {
                        appState.selectAll()
                    }
                    if !appState.displayedAssets.isEmpty {
                        Button("Export All (\(appState.displayedAssets.count)) Images... (⇧⌘E)") {
                            appState.selectAll()
                            appState.exportPhotos(assets: appState.displayedAssets)
                        }
                    }
                }
                .onChange(of: appState.primarySelectedAssetID) { _, newID in
                    if let newID = newID {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
            .onAppear {
                calculateGridColumns(width: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                calculateGridColumns(width: newWidth)
            }
            .onChange(of: appState.thumbnailSize) { _, _ in
                calculateGridColumns(width: geometry.size.width)
            }
        }
    }
    
    private func calculateGridColumns(width: CGFloat) {
        let availableWidth = max(0, width - 24)
        let itemWidthWithSpacing = appState.thumbnailSize + 10
        let count = max(1, Int((availableWidth + 10) / itemWidthWithSpacing))
        if appState.gridColumnsCount != count {
            DispatchQueue.main.async {
                self.appState.gridColumnsCount = count
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(LightroomTheme.textMuted.opacity(0.4))
            
            if appState.currentFolderURL == nil {
                Text("No Folder Opened")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LightroomTheme.textPrimary)
                
                Text("Select a folder containing RAW or image files from the left sidebar.")
                    .font(.system(size: 12))
                    .foregroundColor(LightroomTheme.textSecondary)
            } else if appState.allAssets.isEmpty {
                Text("No Compatible Photos Found")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LightroomTheme.textPrimary)
                
                Text("Supported formats: .ARW, .CR2, .CR3, .NEF, .DNG, .RAF, .JPG, .TIFF")
                    .font(.system(size: 12))
                    .foregroundColor(LightroomTheme.textSecondary)
            } else {
                Text("No Photos Match Filter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LightroomTheme.textPrimary)
                
                Button("Clear Filter") {
                    appState.filterCriteria.reset()
                }
                .buttonStyle(.borderedProminent)
                .accentColor(LightroomTheme.accentYellow)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    @ViewBuilder
    private func gridContextMenu(for asset: PhotoAsset) -> some View {
        Button("Open in Loupe View (E)") {
            appState.selectAsset(asset)
            appState.viewMode = .loupe
        }
        
        Divider()
        
        Menu("Set Rating") {
            Button("None (0)") { appState.selectAsset(asset); appState.setRating(0) }
            Button("★☆☆☆☆ (1)") { appState.selectAsset(asset); appState.setRating(1) }
            Button("★★☆☆☆ (2)") { appState.selectAsset(asset); appState.setRating(2) }
            Button("★★★☆☆ (3)") { appState.selectAsset(asset); appState.setRating(3) }
            Button("★★★★☆ (4)") { appState.selectAsset(asset); appState.setRating(4) }
            Button("★★★★★ (5)") { appState.selectAsset(asset); appState.setRating(5) }
        }
        
        Menu("Flag Status") {
            Button("Pick (P)") { appState.selectAsset(asset); appState.setFlag(.pick) }
            Button("Reject (X)") { appState.selectAsset(asset); appState.setFlag(.reject) }
            Button("Unflag (U)") { appState.selectAsset(asset); appState.setFlag(.unflagged) }
        }
        
        Divider()
        
        let selectedCount = appState.selectedAssets.count
        let totalCount = appState.displayedAssets.count
        let isBatch = appState.selectedAssetIDs.contains(asset.id) && selectedCount > 1
        let isAll = isBatch && selectedCount == totalCount
        
        let exportTitle = isAll ? "Export All (\(selectedCount)) Images... (⇧⌘E)" :
                          (isBatch ? "Export \(selectedCount) Photos... (⇧⌘E)" : "Export to JPEG... (⇧⌘E)")
        
        Button(exportTitle) {
            if isBatch {
                appState.exportPhotos(assets: appState.selectedAssets)
            } else {
                appState.selectAsset(asset)
                appState.exportPhotos(assets: [asset])
            }
        }
        
        if !isAll && totalCount > 1 {
            Button("Export All (\(totalCount)) Images...") {
                appState.selectAll()
                appState.exportPhotos(assets: appState.displayedAssets)
            }
        }
        
        Divider()
        
        Button("Select All (⌘A)") {
            appState.selectAll()
        }
        
        if selectedCount > 1 {
            Button("Deselect All (⌘D)") {
                appState.deselectAll()
            }
        }
        
        Divider()
        
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
        }
        
        if asset.hasSidecarXMP {
            Button("Reveal XMP Sidecar in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.sidecarXMPURL])
            }
        }
        
        Divider()
        
        Button("Move to Trash (⌘⌫)", role: .destructive) {
            if appState.selectedAssetIDs.contains(asset.id) {
                appState.requestDeleteSelectedPhotos()
            } else {
                appState.requestDeleteSelectedPhotos(targets: [asset])
            }
        }
    }
}
