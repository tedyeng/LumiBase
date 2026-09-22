import SwiftUI
import AppKit
import OSLog

/// Source coordinates are normalized in the oriented, processed image.
struct InspectionState {
    var persistent = false
    var held = false
    var center = CGPoint(x: 0.5, y: 0.5)
    var zoomed: Bool { persistent || held }

    mutating func begin(at point: CGPoint, pixels: CGSize, viewport: CGSize) {
        if !zoomed {
            let size = displaySize(pixels: pixels, viewport: viewport, backing: 1)
            center = CGPoint(x: (point.x - (viewport.width - size.width) / 2) / max(1, size.width),
                             y: (point.y - (viewport.height - size.height) / 2) / max(1, size.height))
        }
        held = true
    }
    mutating func end() { held = false }
    mutating func clamp(displayed: CGSize, viewport: CGSize) {
        func axis(_ value: CGFloat, _ size: CGFloat, _ view: CGFloat) -> CGFloat {
            guard size > view else { return 0.5 }
            let inset = view / (2 * size)
            return min(1 - inset, max(inset, value))
        }
        center.x = axis(center.x, displayed.width, viewport.width)
        center.y = axis(center.y, displayed.height, viewport.height)
    }
    mutating func pan(delta: CGSize, displayed: CGSize, viewport: CGSize) {
        center.x -= delta.width / max(1, displayed.width)
        center.y -= delta.height / max(1, displayed.height)
        clamp(displayed: displayed, viewport: viewport)
    }
    func displaySize(pixels: CGSize, viewport: CGSize, backing: CGFloat) -> CGSize {
        let scale = zoomed ? 1 / max(1, backing) : min(viewport.width / max(1, pixels.width), viewport.height / max(1, pixels.height))
        return CGSize(width: pixels.width * scale, height: pixels.height * scale)
    }
}


struct InspectionWheelGate {
    private var lastStep = -Double.infinity
    private var accumulated: CGFloat = 0
    mutating func step(delta: CGFloat, precise: Bool, momentum: Bool, inside: Bool, time: Double) -> Int {
        guard inside, !momentum, delta != 0 else { return 0 }
        guard time - lastStep >= 0.18 else { accumulated = 0; return 0 }
        if accumulated * delta < 0 { accumulated = 0 }
        accumulated += delta
        guard !precise || abs(accumulated) >= 20 else { return 0 }
        lastStep = time
        accumulated = 0
        return delta < 0 ? 1 : -1
    }
}
struct InspectionRevision {
    private var value = UUID()
    mutating func next() -> UUID { value = UUID(); return value }
    func accepts(_ candidate: UUID) -> Bool { value == candidate }
}

/// One visible frame, replaced only by a valid result for the current request.
struct InspectionDisplay {
    private(set) var image: NSImage?
    private(set) var filename = ""
    private(set) var pixels = CGSize(width: 1, height: 1)
    private(set) var native = false
    private var revision = InspectionRevision()
    mutating func begin(filename: String) -> UUID { revision.next() }
    mutating func accept(_ image: NSImage?, filename: String, pixels: CGSize, native: Bool, ticket: UUID) {
        guard revision.accepts(ticket), let image else { return }
        self.image = image
        self.filename = filename
        self.pixels = pixels
        self.native = native
    }
}

/// Native mouse delivery avoids competing SwiftUI click/drag recognizers.
struct InspectionSurface: NSViewRepresentable {
    var down: (CGPoint, Int) -> Void
    var drag: (CGSize) -> Void
    var up: () -> Void
    var navigate: (Int) -> Void
    var backingChanged: (CGFloat) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.owner = self
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        view.endCapture()
        view.owner = nil
    }
    final class Surface: NSView {
        var owner: InspectionSurface?
        var wheel = InspectionWheelGate()
        var lastPoint: CGPoint?
        private var captureMonitor: Any?
        private var captureObservers: [NSObjectProtocol] = []
        private var lastWheelEvent: NSEvent?
        var hasCaptureMonitor: Bool { captureMonitor != nil }
        private let logger = Logger(subsystem: "com.lumibase.inspection", category: "mouse")
        private var pressTime: TimeInterval?
        private var pressPoint: CGPoint?
        private var doubleClickCandidate = false
        private var previousShortClick = false
        private var usedInspection = false

        // AppKit delivers local monitors on the main thread. Never change first responder
        // or install a key monitor: AppState retains ownership of keyboard shortcuts.
        private func beginCapture() {
            captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return self.routeCapturedEvent(event, leftPressed: NSEvent.pressedMouseButtons & 1 != 0)
            }
            let center = NotificationCenter.default
            captureObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.endCapture()
            })
            if let window {
                for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                    captureObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.endCapture()
                    })
                }
            }
        }

        func endCapture() {
            let wasHeld = lastPoint != nil
            if wasHeld { logger.debug("capture ended; releasing temporary hold") }
            pressTime = nil
            pressPoint = nil
            doubleClickCandidate = false
            previousShortClick = false
            usedInspection = false
            lastPoint = nil
            if let monitor = captureMonitor { NSEvent.removeMonitor(monitor) }
            captureMonitor = nil
            captureObservers.forEach(NotificationCenter.default.removeObserver)
            captureObservers.removeAll()
            if wasHeld { owner?.up() }
        }

        private func finishPress(with event: NSEvent) {
            guard let start = pressTime, let point = pressPoint else { endCapture(); return }
            let end = convert(event.locationInWindow, from: nil)
            let shortClick = !usedInspection && event.timestamp - start <= NSEvent.doubleClickInterval
                && hypot(end.x - point.x, end.y - point.y) <= 4 && bounds.contains(end)
            let toggle = doubleClickCandidate && shortClick
            endCapture()
            previousShortClick = shortClick && !toggle
            if toggle { owner?.down(point, 2) }
            logger.debug("release short=\(shortClick) persistentToggle=\(toggle)")
        }

        // Shared seam for monitor routing tests; only an active gesture may consume.
        func routeCapturedEvent(_ event: NSEvent, leftPressed: Bool) -> NSEvent? {
            guard lastPoint != nil else { return event }
            if event.type == .leftMouseUp {
                finishPress(with: event)
                return event // let AppKit finish its native mouse tracking; cleanup is idempotent
            }
            guard leftPressed else { endCapture(); return event }
            guard event.type == .scrollWheel, event.window === window else { return event }
            scrollWheel(with: event)
            return nil // prevent normal hit-tested scrollWheel from delivering it again
        }

        override func cancelOperation(_ sender: Any?) { endCapture() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { endCapture() }
            super.viewWillMove(toWindow: newWindow)
        }
        deinit {
            if let monitor = captureMonitor { NSEvent.removeMonitor(monitor) }
            captureObservers.forEach(NotificationCenter.default.removeObserver)
        }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportBacking() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); reportBacking() }
        private func reportBacking() {
            let scale = window?.backingScaleFactor ?? 1
            DispatchQueue.main.async { [weak self] in self?.owner?.backingChanged(scale) }
        }
        override func mouseDown(with event: NSEvent) {
            let previousWasClick = previousShortClick
            endCapture()
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            logger.debug("down count=\(event.clickCount) key=\(self.window?.isKeyWindow ?? false) owner=\(self.owner != nil)")
            // Every down inspects immediately. Only a completed short second click
            // toggles persistent zoom; a held/dragged/wheel press must never do so.
            doubleClickCandidate = event.clickCount == 2 && previousWasClick
            pressTime = event.timestamp
            pressPoint = point
            owner?.down(point, 1)
            lastPoint = point
            beginCapture()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let previous = lastPoint else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let start = pressPoint, hypot(point.x - start.x, point.y - start.y) > 4 { usedInspection = true }
            owner?.drag(CGSize(width: point.x - previous.x, height: point.y - previous.y))
            lastPoint = point
        }
        override func mouseUp(with event: NSEvent) {
            // A local monitor may already have completed this exact release.
            if lastPoint != nil { finishPress(with: event) }
        }
        override func scrollWheel(with event: NSEvent) {
            guard lastWheelEvent !== event else { return }
            lastWheelEvent = event
            if lastPoint != nil { usedInspection = true }
            let inside = lastPoint != nil || bounds.contains(convert(event.locationInWindow, from: nil))
            let step = wheel.step(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                  momentum: !event.momentumPhase.isEmpty, inside: inside, time: event.timestamp)
            if step != 0 { owner?.navigate(step) }
        }
    }
}

/// Full-screen high-res Loupe view for inspecting RAW photos with instant preview switching
public struct LoupeView: View {
    @ObservedObject var appState: AppState
    
    @State private var display = InspectionDisplay()
    @State private var displayTicket = UUID()
    @State private var isLoading: Bool = false
    @State private var inspection = InspectionState()
    @State private var backingScale: CGFloat = 2
    @State private var sourcePixels = CGSize(width: 1, height: 1)
    @State private var renderRevision = InspectionRevision()
    @State private var loadRevision = InspectionRevision()
    @State private var imageError: String?
    private var is100PercentZoom: Bool { inspection.zoomed }
    @State private var showInfoOverlay: Bool = true
    
    public var body: some View {
        VStack(spacing: 0) {
            // Main Viewer Area
            GeometryReader { geo in
                let viewportSize = geo.size
                let img = display.image
                
                let pixels = display.pixels
                let size = inspection.displaySize(pixels: pixels, viewport: viewportSize, backing: backingScale)
                var clamped = inspection
                let _ = clamped.clamp(displayed: size, viewport: viewportSize)

                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    if let img = img {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(is100PercentZoom ? .none : .high)
                            .frame(width: size.width, height: size.height)
                            .position(x: viewportSize.width / 2 + (0.5 - clamped.center.x) * size.width,
                                      y: viewportSize.height / 2 + (0.5 - clamped.center.y) * size.height)
                    } else if isLoading {
                        ProgressView().allowsHitTesting(false)
                    } else {
                        Text(imageError ?? "Image unavailable")
                            .foregroundColor(.white).allowsHitTesting(false)
                    }
                    if isLoading || imageError != nil {
                        VStack {
                            Spacer()
                            Text(imageError ?? "Loading \(appState.primarySelectedAsset?.filename ?? "image") — showing \(display.filename.isEmpty ? "preview" : display.filename)")
                                .font(.system(size: 11)).foregroundColor(.white)
                                .padding(8).background(Color.black.opacity(0.7)).cornerRadius(4)
                        }.padding(12).allowsHitTesting(false)
                    }
                    InspectionSurface(
                        down: { point, count in
                            Logger(subsystem: "com.lumibase.inspection", category: "state").debug("intent count=\(count) loading=\(isLoading) nativeFrame=\(display.native) hasFrame=\(display.image != nil) error=\(imageError != nil)")
                            if count == 2 { inspection.end(); toggleZoom() }
                            else {
                                inspection.begin(at: point, pixels: pixels, viewport: viewportSize)
                            }
                        },
                        drag: { delta in
                            guard inspection.held else { return }
                            inspection = clamped
                            inspection.pan(delta: delta, displayed: size, viewport: viewportSize)
                        },
                        up: { inspection.end() },
                        navigate: { step in
                            if step > 0 { appState.selectNextPhoto() } else { appState.selectPreviousPhoto() }
                        },
                        backingChanged: { backingScale = $0 }
                    )

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
                        .allowsHitTesting(false)
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
                                Text(is100PercentZoom ? (display.native && !isLoading && imageError == nil ? "100%" : "Preparing native 100%") : "FIT")
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            inspection.end()
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
        .onChange(of: is100PercentZoom) { _, _ in
            if display.native && !isLoading && imageError == nil { return }
            if let asset = appState.primarySelectedAsset { updateProcessedImage(with: activeXMP(for: asset)) }
        }
        .onDisappear {
            inspection.end()
            _ = loadRevision.next()
            _ = renderRevision.next()
            idleFullRenderTask?.cancel()
        }
        .onChange(of: appState.liveDevelopXMP) { _, newXMP in
            updateProcessedImage(with: newXMP)
        }
        .onChange(of: appState.primarySelectedAsset?.xmp) { _, newXMP in
            updateProcessedImage(with: newXMP)
        }
    }
    
    private func toggleZoom() {
        guard !inspection.held else { return }
        inspection.persistent.toggle()
        if inspection.persistent { inspection.center = CGPoint(x: 0.5, y: 0.5) }
    }

    @State private var currentBaseHolder: BaseImageHolder?
    @State private var holderAssetID: String?
    @State private var idleFullRenderTask: Task<Void, Never>?

    @MainActor
    private func loadSelectedImage() async {
        let ticket = loadRevision.next()
        _ = renderRevision.next()
        idleFullRenderTask?.cancel()
        imageError = nil
        isLoading = false
        currentBaseHolder = nil
        holderAssetID = nil
        guard let asset = appState.primarySelectedAsset else { display = InspectionDisplay(); return }
        let targetID = asset.id
        displayTicket = display.begin(filename: asset.filename)
        let frameTicket = displayTicket
        isLoading = true
        // Decode and thumbnail preparation overlap; native inspection never waits for the thumbnail.
        let thumbnailTask = Task { @MainActor in
            let thumb = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 1600)
            guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID,
                  holderAssetID != targetID, (!is100PercentZoom || display.image == nil) else { return }
            if let thumb {
                display.accept(thumb, filename: asset.filename, pixels: thumb.size, native: false, ticket: frameTicket)
            }
        }
        defer { thumbnailTask.cancel() }
        let xmp = activeXMP(for: asset)
        let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: xmp)
        guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
        currentBaseHolder = holder
        holderAssetID = targetID
        guard let holder else {
            isLoading = false
            imageError = "Unable to decode \(asset.filename). Still showing \(display.filename). Native 100% unavailable."
            return
        }
        sourcePixels = holder.fullExtent.size
        updateProcessedImage(with: activeXMP(for: asset))
    }

    private func activeXMP(for asset: PhotoAsset) -> XMPMetadata {
        if appState.liveDevelopAssetID == asset.id, let xmp = appState.liveDevelopXMP { return xmp }
        return asset.xmp
    }

    private func updateProcessedImage(with xmp: XMPMetadata?) {
        let ticket = renderRevision.next()
        idleFullRenderTask?.cancel()
        guard let asset = appState.primarySelectedAsset, holderAssetID == asset.id, let holder = currentBaseHolder else { return }
        let targetID = asset.id
        let model = asset.cameraMetadata.model
        let native = is100PercentZoom
        imageError = nil
        guard !native || holder.supportsNativeInspection else {
            isLoading = false
            imageError = "Native 100% unavailable for \(asset.filename). Still showing \(display.filename). Release or choose Fit for preview."
            return
        }
        isLoading = true
        // Preserve the existing fast slider path in Fit; refine only after idle.
        if !native {
            LiveDevelopPreviewEngine.shared.requestRender(
                baseHolder: holder, cameraModel: model, xmp: xmp, interactive: true
            ) { result in
                guard renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
                if let result { display.accept(result, filename: asset.filename, pixels: holder.fullExtent.size, native: false, ticket: displayTicket) }
            }
        }
        idleFullRenderTask = Task { @MainActor in
            if !native {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            // Reuse the established RAW decode and color pipeline, including WB.
            let fresh = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: xmp) ?? holder
            guard !Task.isCancelled, renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
            currentBaseHolder = fresh
            sourcePixels = fresh.fullExtent.size
            LiveDevelopPreviewEngine.shared.requestRender(
                baseHolder: fresh, cameraModel: model, xmp: xmp,
                interactive: false, fullResolution: native
            ) { result in
                guard renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
                display.accept(result, filename: asset.filename, pixels: fresh.fullExtent.size, native: native, ticket: displayTicket)
                isLoading = false
                imageError = result == nil ? "Unable to render \(asset.filename). Still showing \(display.filename). Choose another photo to continue." : nil
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
