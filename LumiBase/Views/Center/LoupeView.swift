import SwiftUI
import AppKit

/// Full-screen high-res Loupe view for inspecting RAW photos with instant preview switching
public struct LoupeView: View {
    @ObservedObject var appState: AppState
    
    @State private var previewImage: NSImage?
    @State private var fullImage: NSImage?
    @State private var isLoading: Bool = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var is100PercentZoom: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero
    @State private var showInfoOverlay: Bool = true
    
    public var body: some View {
        VStack(spacing: 0) {
            // Main Viewer Area
            GeometryReader { geo in
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    // Display either high-res image or fast preview thumbnail
                    if let img = fullImage ?? previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: is100PercentZoom ? .fill : .fit)
                            .scaleEffect(is100PercentZoom ? 2.5 : zoomScale)
                            .offset(dragOffset)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if is100PercentZoom || zoomScale > 1.0 {
                                            dragOffset = CGSize(
                                                width: lastDragOffset.width + value.translation.width,
                                                height: lastDragOffset.height + value.translation.height
                                            )
                                        }
                                    }
                                    .onEnded { _ in
                                        lastDragOffset = dragOffset
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    is100PercentZoom.toggle()
                                    if !is100PercentZoom {
                                        dragOffset = .zero
                                        lastDragOffset = .zero
                                        zoomScale = 1.0
                                    }
                                }
                            }
                    } else if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading RAW Preview...")
                                .font(.system(size: 12))
                                .foregroundColor(LightroomTheme.textSecondary)
                        }
                    }
                    
                    // Left / Right Navigation Buttons (Hover)
                    HStack {
                        Button {
                            appState.selectPreviousPhoto()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 80)
                                .background(Color.black.opacity(0.4))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                        
                        Spacer()
                        
                        Button {
                            appState.selectNextPhoto()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 80)
                                .background(Color.black.opacity(0.4))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                    }
                    
                    // Top-Left EXIF & XMP Overlay
                    if showInfoOverlay, let asset = appState.primarySelectedAsset {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(asset.filename)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                
                                if asset.xmp.isLoadedFromSidecar {
                                    HStack(spacing: 3) {
                                        Circle().fill(Color.green).frame(width: 6, height: 6)
                                        Text("XMP")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .cornerRadius(3)
                                }
                            }
                            
                            if !asset.cameraMetadata.exposureSummary.isEmpty {
                                Text(asset.cameraMetadata.exposureSummary)
                                    .font(.system(size: 11))
                                    .foregroundColor(LightroomTheme.textSecondary)
                            }
                            
                            if let model = asset.cameraMetadata.model {
                                Text(model)
                                    .font(.system(size: 11))
                                    .foregroundColor(LightroomTheme.textMuted)
                            }
                            
                            if asset.xmp.hasDevelopEdits {
                                HStack(spacing: 6) {
                                    Image(systemName: "slider.horizontal.2.square")
                                        .font(.system(size: 10))
                                    Text(developSummary(for: asset))
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(LightroomTheme.accentYellow)
                                .padding(.top, 2)
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                    }
                    
                    // Top-Right Zoom Mode & Rating Bar
                    if let asset = appState.primarySelectedAsset {
                        HStack(spacing: 12) {
                            // Zoom Indicator Button
                            Button {
                                withAnimation {
                                    is100PercentZoom.toggle()
                                    if !is100PercentZoom {
                                        dragOffset = .zero
                                        lastDragOffset = .zero
                                    }
                                }
                            } label: {
                                Text(is100PercentZoom ? "100%" : "FIT")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(LightroomTheme.accentYellow)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            
                            // Rating Stars
                            RatingStarsView(
                                rating: asset.xmp.rating,
                                starSize: 13,
                                isInteractive: true,
                                onRatingChanged: { newRating in
                                    appState.setRating(newRating)
                                }
                            )
                            
                            // Flag Status
                            FlagBadgeView(flag: asset.xmp.flag, size: 14, isInteractive: true) {
                                let next: FlagStatus
                                switch asset.xmp.flag {
                                case .unflagged: next = .pick
                                case .pick: next = .reject
                                case .reject: next = .unflagged
                                }
                                appState.setFlag(next)
                            }
                            
                            // Export Button
                            Button {
                                if !appState.selectedAssets.isEmpty {
                                    appState.exportPhotos(assets: appState.selectedAssets)
                                } else {
                                    appState.exportPhotos(assets: [asset])
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 11))
                                    Text(appState.selectedAssets.count > 1 ? "Export (\(appState.selectedAssets.count))" : "Export")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Export to High-Quality JPEG (⇧⌘E)")
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                    }
                }
                .contextMenu {
                    if !appState.selectedAssets.isEmpty {
                        Button("Export Selected (\(appState.selectedAssets.count)) to JPEG... (⇧⌘E)") {
                            appState.exportPhotos(assets: appState.selectedAssets)
                        }
                    } else if let asset = appState.primarySelectedAsset {
                        Button("Export to JPEG... (⇧⌘E)") {
                            appState.exportPhotos(assets: [asset])
                        }
                    }
                    Button("Export All (\(appState.displayedAssets.count)) Images...") {
                        appState.exportPhotos(assets: appState.displayedAssets)
                    }
                    Divider()
                    Button("Select All (⌘A)") {
                        appState.selectAll()
                    }
                    if !appState.selectedAssetIDs.isEmpty {
                        Button("Deselect All (⌘D)") {
                            appState.deselectAll()
                        }
                    }
                    Divider()
                    if let asset = appState.primarySelectedAsset {
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
                            appState.requestDeleteSelectedPhotos()
                        }
                    }
                }
            }
            
            // Bottom Filmstrip
            if appState.isFilmstripVisible {
                Divider().background(LightroomTheme.dividerColor)
                FilmstripView(appState: appState)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(KeyEquivalent("a")) {
            if NSEvent.modifierFlags.contains(.command) {
                appState.selectAll()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("d")) {
            if NSEvent.modifierFlags.contains(.command) {
                appState.deselectAll()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            if NSEvent.modifierFlags.contains(.command) {
                appState.requestDeleteSelectedPhotos()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            appState.selectPreviousPhoto()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            appState.selectNextPhoto()
            return .handled
        }
        .onKeyPress(.upArrow) {
            appState.selectPreviousPhoto()
            return .handled
        }
        .onKeyPress(.downArrow) {
            appState.selectNextPhoto()
            return .handled
        }
        .task(id: appState.primarySelectedAssetID) {
            await loadSelectedImage()
        }
        .onChange(of: appState.liveDevelopXMP) { _, newXMP in
            updateProcessedImage(with: newXMP)
        }
        .onChange(of: appState.primarySelectedAsset?.xmp) { _, newXMP in
            updateProcessedImage(with: newXMP)
        }
    }
    
    @State private var currentBaseHolder: BaseImageHolder?
    @State private var liveRenderTask: Task<Void, Never>?
    @State private var idleFullRenderTask: Task<Void, Never>?
    
    private func loadSelectedImage() async {
        guard let asset = appState.primarySelectedAsset else {
            previewImage = nil
            fullImage = nil
            currentBaseHolder = nil
            return
        }
        
        let targetID = asset.id
        
        // 1. Immediately reset fullImage of old photo so it does not block the new photo
        fullImage = nil
        currentBaseHolder = nil
        dragOffset = .zero
        lastDragOffset = .zero
        liveRenderTask?.cancel()
        idleFullRenderTask?.cancel()
        
        // 2. Immediately load fast preview thumbnail for zero-latency response
        let cachedThumb = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 1600)
        
        guard appState.primarySelectedAssetID == targetID else { return }
        self.previewImage = cachedThumb
        self.isLoading = (cachedThumb == nil)
        
        // 3. Decode base neutral RAW holder (display proxy + full res) in background
        let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL)
        
        guard appState.primarySelectedAssetID == targetID, let baseHolder = holder else {
            self.isLoading = false
            return
        }
        
        self.currentBaseHolder = baseHolder
        
        // 4. Immediately render interactive display proxy (< 1.5ms on Metal)
        let activeXMP = (appState.liveDevelopAssetID == targetID && appState.liveDevelopXMP != nil) ? appState.liveDevelopXMP! : asset.xmp
        if let img = RAWImageLoader.shared.renderProcessed(
            baseHolder: baseHolder,
            cameraModel: asset.cameraMetadata.model,
            xmp: activeXMP,
            interactive: true
        ) {
            self.fullImage = img
        }
        self.isLoading = false
        
        // 5. Background idle full-res render
        scheduleIdleFullRender(for: targetID, xmp: activeXMP)
    }
    
    private func updateProcessedImage(with xmp: XMPMetadata?) {
        guard let holder = currentBaseHolder, let asset = appState.primarySelectedAsset else { return }
        let targetID = asset.id
        let targetModel = asset.cameraMetadata.model
        
        // Coalesced sub-millisecond background GPU render
        LiveDevelopPreviewEngine.shared.requestRender(
            baseHolder: holder,
            cameraModel: targetModel,
            xmp: xmp,
            interactive: true
        ) { newImage in
            guard self.appState.primarySelectedAssetID == targetID else { return }
            self.fullImage = newImage
        }
        
        // Schedule background full-res update when user stops moving slider
        scheduleIdleFullRender(for: targetID, xmp: xmp)
    }
    
    private func scheduleIdleFullRender(for assetID: String, xmp: XMPMetadata?) {
        idleFullRenderTask?.cancel()
        idleFullRenderTask = Task(priority: .utility) { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms idle
            guard !Task.isCancelled, let holder = currentBaseHolder, appState.primarySelectedAssetID == assetID else { return }
            
            let model = appState.primarySelectedAsset?.cameraMetadata.model
            LiveDevelopPreviewEngine.shared.requestRender(
                baseHolder: holder,
                cameraModel: model,
                xmp: xmp,
                interactive: false
            ) { fullImg in
                guard self.appState.primarySelectedAssetID == assetID else { return }
                self.fullImage = fullImg
            }
        }
    }
    
    private func developSummary(for asset: PhotoAsset) -> String {
        var parts: [String] = []
        if let ev = asset.xmp.exposure2012 {
            parts.append(String(format: "Exp: %+.2f EV", ev))
        }
        if let temp = asset.xmp.temperature {
            parts.append("Temp: \(temp)K")
        }
        if let c = asset.xmp.contrast2012 {
            parts.append(String(format: "Contrast: %+d", c))
        }
        return parts.joined(separator: " • ")
    }
}
