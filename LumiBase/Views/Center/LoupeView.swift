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
                let viewportSize = geo.size
                let img = fullImage ?? previewImage
                
                // Precise pan boundaries calculation based on aspect ratio
                let imgWidth = img?.size.width ?? 1
                let imgHeight = img?.size.height ?? 1
                let imgAspect = imgWidth / max(1, imgHeight)
                let viewAspect = viewportSize.width / max(1, viewportSize.height)
                
                let fittedWidth: CGFloat = (imgAspect > viewAspect) ? viewportSize.width : (viewportSize.height * imgAspect)
                let fittedHeight: CGFloat = (imgAspect > viewAspect) ? (viewportSize.width / imgAspect) : viewportSize.height
                
                let zoomFactor: CGFloat = is100PercentZoom ? 2.5 : 1.0
                let scaledWidth = fittedWidth * zoomFactor
                let scaledHeight = fittedHeight * zoomFactor
                
                let maxPanX = max(0, (scaledWidth - viewportSize.width) / 2)
                let maxPanY = max(0, (scaledHeight - viewportSize.height) / 2)
                
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    // Display either high-res image or fast preview thumbnail
                    if let img = img {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoomFactor)
                            .offset(
                                x: min(maxPanX, max(-maxPanX, dragOffset.width)),
                                y: min(maxPanY, max(-maxPanY, dragOffset.height))
                            )
                            .frame(width: viewportSize.width, height: viewportSize.height)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if is100PercentZoom {
                                            let targetX = lastDragOffset.width + value.translation.width
                                            let targetY = lastDragOffset.height + value.translation.height
                                            dragOffset = CGSize(
                                                width: min(maxPanX, max(-maxPanX, targetX)),
                                                height: min(maxPanY, max(-maxPanY, targetY))
                                            )
                                        }
                                    }
                                    .onEnded { _ in
                                        lastDragOffset = dragOffset
                                    }
                            )
                            .onTapGesture(count: 2) {
                                toggleZoom()
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
                    
                    // Left / Right Navigation Buttons (Only shown when not zoomed to 100%)
                    if !is100PercentZoom {
                        HStack {
                            Button {
                                appState.selectPreviousPhoto()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(width: 32, height: 60)
                                    .background(Color.black.opacity(0.35))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 8)
                            
                            Spacer()
                            
                            Button {
                                appState.selectNextPhoto()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(width: 32, height: 60)
                                    .background(Color.black.opacity(0.35))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)
                        }
                        .transition(.opacity)
                    }
                    
                    // Top-Left EXIF & XMP Overlay (HUD)
                    if showInfoOverlay, let asset = appState.primarySelectedAsset {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(asset.filename)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                
                                if asset.isRawPlusJPG {
                                    Text("RAW+JPG")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1.5)
                                        .background(Color.blue.opacity(0.85))
                                        .cornerRadius(2)
                                } else if asset.isRaw {
                                    Text(asset.fileExtension.uppercased())
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1.5)
                                        .background(Color.black.opacity(0.6))
                                        .cornerRadius(2)
                                }
                                
                                if asset.xmp.isLoadedFromSidecar {
                                    HStack(spacing: 2) {
                                        Text("XMP")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.white)
                                        if asset.xmp.hasDevelopEdits {
                                            Text("±")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(LightroomTheme.accentYellow)
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1.5)
                                    .background(Color.green.opacity(0.85))
                                    .cornerRadius(2)
                                }
                            }
                            
                            if !asset.cameraMetadata.exposureSummary.isEmpty {
                                Text(asset.cameraMetadata.exposureSummary)
                                    .font(.system(size: 10))
                                    .foregroundColor(LightroomTheme.textSecondary)
                            }
                            
                            if let model = asset.cameraMetadata.model {
                                Text(model)
                                    .font(.system(size: 10))
                                    .foregroundColor(LightroomTheme.textMuted)
                            }
                            
                            if asset.xmp.hasDevelopEdits {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.2.square")
                                        .font(.system(size: 9))
                                    Text(developSummary(for: asset))
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(LightroomTheme.accentYellow)
                                .padding(.top, 1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .transition(.opacity)
                    }
                    
                    // Top-Right Lightweight Control Pill (Zoom & Info toggle)
                    HStack(spacing: 6) {
                        // Zoom Mode Toggle (FIT / 100%)
                        Button {
                            toggleZoom()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: is100PercentZoom ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9))
                                Text(is100PercentZoom ? "100%" : "FIT")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(LightroomTheme.accentYellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Zoom 100% / Fit (Z or Double-Click)")
                        
                        // Info Overlay Toggle Button
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showInfoOverlay.toggle()
                            }
                        } label: {
                            Image(systemName: showInfoOverlay ? "info.circle.fill" : "info.circle")
                                .font(.system(size: 11))
                                .foregroundColor(showInfoOverlay ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Photo Info (I)")
                        
                        // Back to Grid Button
                        Button {
                            appState.viewMode = .grid
                        } label: {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 11))
                                .foregroundColor(LightroomTheme.textSecondary)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Back to Grid View (G / Esc)")
                    }
                    .padding(5)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                }
                .clipped()
                .contentShape(Rectangle())
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseToggleZoom"))) { _ in
            toggleZoom()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseToggleInfoOverlay"))) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                showInfoOverlay.toggle()
            }
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
    
    private func toggleZoom() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            is100PercentZoom.toggle()
            if !is100PercentZoom {
                dragOffset = .zero
                lastDragOffset = .zero
            }
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
        
        let activeXMP = (appState.liveDevelopAssetID == targetID && appState.liveDevelopXMP != nil) ? appState.liveDevelopXMP! : asset.xmp
        
        // 3. Decode base neutral RAW holder (display proxy + full res) in background
        let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: activeXMP)
        
        guard appState.primarySelectedAssetID == targetID, let baseHolder = holder else {
            self.isLoading = false
            return
        }
        
        self.currentBaseHolder = baseHolder
        
        // 4. Immediately render interactive display proxy (< 1.5ms on Metal)
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
            guard !Task.isCancelled, let asset = appState.primarySelectedAsset, asset.id == assetID, appState.primarySelectedAssetID == assetID else { return }
            
            var holder = currentBaseHolder
            if let h = holder, h.isRaw {
                let currentEV = Float(xmp?.exposure2012 ?? 0.0)
                let baseEV = h.baseExposure ?? 0.0
                let currentTemp = Float(xmp?.temperature ?? 0)
                let baseTemp = h.baseTemperature ?? 0.0
                if abs(currentEV - baseEV) >= 0.1 || (currentTemp > 0 && abs(currentTemp - baseTemp) >= 50) {
                    if let freshHolder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: xmp) {
                        holder = freshHolder
                        self.currentBaseHolder = freshHolder
                    }
                }
            }
            
            guard let validHolder = holder else { return }
            let model = asset.cameraMetadata.model
            LiveDevelopPreviewEngine.shared.requestRender(
                baseHolder: validHolder,
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
