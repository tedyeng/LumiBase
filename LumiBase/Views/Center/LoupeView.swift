import SwiftUI
import AppKit
import OSLog
import ImageIO

/// Path-free trace for the inspection pipeline. High-frequency input is sampled per event type.
enum InspectionTrace {
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.lumibase.inspection", category: "trace")
    private static var emitted = 0
    private static var lastSample: [String: TimeInterval] = [:]
    static func event(_ name: String, state: InspectionState? = nil, requestID: UUID? = nil, highFrequency: Bool = false) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if highFrequency {
            if let last = lastSample[name], now - last < 0.1 { lock.unlock(); return }
            lastSample[name] = now
        }
        emitted += 1
        let sequence = emitted
        lock.unlock()
        let actual = state.map { " held=\($0.held) persistent=\($0.persistent) zoomed=\($0.zoomed)" } ?? ""
        let request = requestID.map { " request=\($0.uuidString)" } ?? ""
        logger.debug("#\(sequence) \(name, privacy: .public)\(actual, privacy: .public)\(request, privacy: .public)")
    }
}

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
    mutating func applyDrag(delta: CGSize, displayed: CGSize, viewport: CGSize) {
        clamp(displayed: displayed, viewport: viewport)
        pan(delta: delta, displayed: displayed, viewport: viewport)
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

/// Coalesces continuous ROI movement into bounded, latest-request submissions.
struct InspectionROIThrottle {
    static let interval: TimeInterval = 0.025
    private(set) var pendingSince: TimeInterval?
    private(set) var lastSubmission: TimeInterval?

    mutating func dueTime(forRequestAt now: TimeInterval) -> TimeInterval {
        let first = pendingSince ?? now
        pendingSince = first
        return max(first + Self.interval, (lastSubmission ?? -.infinity) + Self.interval)
    }
    mutating func submitted(at time: TimeInterval) {
        lastSubmission = time
        pendingSince = nil
    }
    mutating func cancelPending() { pendingSince = nil }
}

/// A bounded native-pixel window around the current normalized inspection center.
enum InspectionROI {
    static func requestRect(enabled: Bool, nativeSupported: Bool, extent: CGRect, center: CGPoint, viewport: CGSize, backing: CGFloat) -> CGRect? {
        guard enabled, nativeSupported else { return nil }
        let rect = sourceRect(extent: extent, center: center, viewport: viewport, backing: backing)
        return rect.isEmpty ? nil : rect
    }
    static func sourceRect(extent: CGRect, center: CGPoint, viewport: CGSize, backing: CGFloat, buffer: CGFloat = 256) -> CGRect {
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return .zero }
        let scale = max(1, backing.isFinite ? backing : 1)
        let requested = CGSize(width: max(1, viewport.width * scale) + max(0, buffer) * 2,
                               height: max(1, viewport.height * scale) + max(0, buffer) * 2)
        let width = min(extent.width, ceil(requested.width))
        let height = min(extent.height, ceil(requested.height))
        let cx = extent.minX + min(1, max(0, center.x)) * extent.width
        // InspectionState uses top-origin normalized y; Core Image extents use bottom-origin y.
        let cy = extent.maxY - min(1, max(0, center.y)) * extent.height
        let x = min(extent.maxX - width, max(extent.minX, floor(cx - width / 2)))
        let y = min(extent.maxY - height, max(extent.minY, floor(cy - height / 2)))
        return CGRect(x: x, y: y, width: width, height: height).intersection(extent)
    }
}

struct InspectionROIToggle {
    private(set) var enabled = true
    mutating func toggle() { enabled.toggle() }
}

struct InspectionCachedROITransition {
    enum HolderAction: Equatable { case keepCachedNativeROI, renderFullFit, loadFullFitPreview }
    private(set) var roiPublished = false
    private(set) var holderReady = false
    private(set) var fitRequested = false
    var keepsCachedROIWhilePreparing: Bool { roiPublished && !holderReady }
    var needsBaseHolder: Bool { roiPublished && !holderReady }
    mutating func publishCachedROI() -> Bool { roiPublished = true; return true }
    mutating func requestFit() { fitRequested = true }
    mutating func baseHolderPrepared(isZoomed: Bool) -> HolderAction {
        holderReady = true
        if fitRequested && !isZoomed { fitRequested = false; return .renderFullFit }
        return .keepCachedNativeROI
    }
    func shouldCompletePreviewSelectionAfterHolderPreparation(isZoomed: Bool) -> Bool {
        roiPublished && holderReady && isZoomed && !fitRequested
    }
    mutating func baseHolderFailed() -> HolderAction {
        if fitRequested { fitRequested = false; return .loadFullFitPreview }
        return .keepCachedNativeROI
    }
}

struct InspectionROIForegroundLifecycle {
    private(set) var activeOwner: String?
    mutating func begin(_ owner: String) { activeOwner = owner }
    mutating func finish(_ owner: String) -> String? {
        guard activeOwner == owner else { return nil }
        activeOwner = nil
        return owner
    }
    mutating func finishCurrent() -> String? {
        guard let owner = activeOwner else { return nil }
        activeOwner = nil
        return owner
    }
}

/// One visible frame, replaced only by a valid result for the current request.
struct InspectionDisplay {
    private(set) var image: NSImage?
    private(set) var assetID: String?
    private(set) var filename = ""
    private(set) var pixels = CGSize(width: 1, height: 1)
    private(set) var native = false
    private(set) var sourceRect: CGRect?
    private(set) var fullExtent: CGRect = .zero
    private var lastFullFit: Frame?
    private var revision = InspectionRevision()
    private struct Frame {
        var image: NSImage
        var assetID: String?
        var filename: String
        var pixels: CGSize
        var native: Bool
        var sourceRect: CGRect?
        var fullExtent: CGRect
    }
    mutating func begin(filename: String) -> UUID {
        assetID = "legacy:\(filename)"
        return revision.next()
    }
    mutating func beginSelection(assetID: String, filename: String) -> UUID {
        let ticket = revision.next()
        self.assetID = assetID
        image = nil
        self.filename = ""
        pixels = CGSize(width: 1, height: 1)
        native = false
        sourceRect = nil
        fullExtent = .zero
        lastFullFit = nil
        return ticket
    }
    func owns(assetID candidate: String?) -> Bool { assetID != nil && assetID == candidate }
    mutating func accept(_ image: NSImage?, filename: String, pixels: CGSize, native: Bool, ticket: UUID, sourceRect: CGRect? = nil, fullExtent: CGRect? = nil) {
        accept(image, assetID: assetID, filename: filename, pixels: pixels, native: native, ticket: ticket, sourceRect: sourceRect, fullExtent: fullExtent)
    }
    mutating func accept(_ image: NSImage?, assetID: String?, filename: String, pixels: CGSize, native: Bool, ticket: UUID, sourceRect: CGRect? = nil, fullExtent: CGRect? = nil) {
        guard revision.accepts(ticket), self.assetID == assetID, let image else { return }
        let extent = fullExtent ?? CGRect(origin: .zero, size: pixels)
        self.image = image
        self.filename = filename
        self.pixels = pixels
        self.native = native
        self.sourceRect = sourceRect
        self.fullExtent = extent
        if sourceRect == nil {
            lastFullFit = Frame(image: image, assetID: assetID, filename: filename, pixels: pixels, native: native, sourceRect: nil, fullExtent: extent)
        }
    }
    mutating func restoreFullFit() {
        guard let frame = lastFullFit else { return }
        guard frame.assetID == assetID else { return }
        image = frame.image
        filename = frame.filename
        pixels = frame.pixels
        native = frame.native
        sourceRect = frame.sourceRect
        fullExtent = frame.fullExtent
    }
    mutating func beginSelection(filename: String) -> UUID { beginSelection(assetID: "legacy:\(filename)", filename: filename) }
}

enum InspectionLoadTransition {
    static func beginSelection(for asset: PhotoAsset, display: inout InspectionDisplay) -> UUID {
        display.beginSelection(assetID: asset.id, filename: asset.filename)
    }
}

struct InspectionFrameLayout {
    var imageSize: CGSize
    var clampSize: CGSize
    var originOffset: CGSize
    static func make(pixels: CGSize, sourceRect: CGRect?, fullExtent: CGRect, zoomed: Bool, viewport: CGSize, backing: CGFloat) -> InspectionFrameLayout {
        let scale = max(1, backing)
        let fullPixels = fullExtent.isEmpty ? CGRect(origin: .zero, size: pixels) : fullExtent
        var state = InspectionState()
        state.persistent = zoomed
        guard let sourceRect else {
            let size = state.displaySize(pixels: pixels, viewport: viewport, backing: backing)
            return InspectionFrameLayout(imageSize: size, clampSize: size, originOffset: .zero)
        }
        let fullSize = CGSize(width: fullPixels.width / scale, height: fullPixels.height / scale)
        return InspectionFrameLayout(
            imageSize: CGSize(width: pixels.width / scale, height: pixels.height / scale),
            clampSize: fullSize,
            originOffset: CGSize(width: (sourceRect.midX - fullPixels.midX) / scale, height: -(sourceRect.midY - fullPixels.midY) / scale)
        )
    }
    static func canReuseNativeFrame(isNative: Bool, isROI: Bool, zoomed: Bool) -> Bool {
        isNative && zoomed && !isROI
    }
    static func leaveNative(display: inout InspectionDisplay) { display.restoreFullFit() }
    static func disableROI(display: inout InspectionDisplay) { display.restoreFullFit() }
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
            if wasHeld { InspectionTrace.event("input.capture_end_release") }
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
            InspectionTrace.event("input.down_accepted")
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
            InspectionTrace.event("input.drag", highFrequency: true)
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
    private var displayForSelectedAsset: InspectionDisplay {
        display.owns(assetID: appState.primarySelectedAssetID) ? display : InspectionDisplay()
    }
    
    @State private var display = InspectionDisplay()
    @State private var displayTicket = UUID()
    @State private var isLoading: Bool = false
    @State private var inspection = InspectionState()
    @State private var backingScale: CGFloat = 2
    @State private var roiPrototypeToggle = InspectionROIToggle()
    private var roiPrototypeEnabled: Bool { roiPrototypeToggle.enabled }
    @State private var viewportPixels = CGSize(width: 1, height: 1)
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
                let visibleDisplay = displayForSelectedAsset
                let img = visibleDisplay.image
                
                let pixels = visibleDisplay.pixels
                let layout = InspectionFrameLayout.make(pixels: pixels, sourceRect: visibleDisplay.sourceRect, fullExtent: visibleDisplay.fullExtent, zoomed: inspection.zoomed, viewport: viewportSize, backing: backingScale)
                let size = layout.imageSize
                let clampSize = layout.clampSize
                var clamped = inspection
                let _ = clamped.clamp(displayed: clampSize, viewport: viewportSize)

                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    if let img = img {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(is100PercentZoom ? .none : .high)
                            .frame(width: size.width, height: size.height)
                            .position(x: viewportSize.width / 2 + (0.5 - clamped.center.x) * (visibleDisplay.sourceRect == nil ? size.width : clampSize.width) + layout.originOffset.width,
                                      y: viewportSize.height / 2 + (0.5 - clamped.center.y) * (visibleDisplay.sourceRect == nil ? size.height : clampSize.height) + layout.originOffset.height)
                    } else if isLoading {
                        ProgressView().allowsHitTesting(false)
                    } else {
                        Text(imageError ?? "Image unavailable")
                            .foregroundColor(.white).allowsHitTesting(false)
                    }
                    if isLoading || imageError != nil {
                        VStack {
                            Spacer()
                            Text(imageError ?? "Loading \(appState.primarySelectedAsset?.filename ?? "image")")
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
                                InspectionTrace.event("state.held_after_down_callback", state: inspection)
                            }
                        },
                        drag: { delta in
                            guard inspection.held else { return }
                            inspection.applyDrag(delta: delta, displayed: clampSize, viewport: viewportSize)
                            if roiPrototypeEnabled, inspection.zoomed, let asset = appState.primarySelectedAsset {
                                updateProcessedImage(with: activeXMP(for: asset))
                            }
                        },
                        up: { inspection.end(); InspectionTrace.event("state.held_after_release_callback", state: inspection) },
                        navigate: { step in
                            if step > 0 { appState.selectNextPhoto() } else { appState.selectPreviousPhoto() }
                        },
                        backingChanged: { scale in
                            backingScale = scale
                            if roiPrototypeEnabled, inspection.zoomed, let asset = appState.primarySelectedAsset {
                                updateProcessedImage(with: activeXMP(for: asset))
                            }
                        }
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
                                Text(is100PercentZoom ? (visibleDisplay.native && !isLoading && imageError == nil ? (visibleDisplay.sourceRect == nil ? "100%" : "ROI 100%") : (roiPrototypeEnabled ? "Preparing ROI 100%" : "Preparing native 100%")) : "FIT")
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

                        Button {
                            roiPrototypeToggle.toggle()
                            if !roiPrototypeEnabled { InspectionFrameLayout.disableROI(display: &display) }
                            if let asset = appState.primarySelectedAsset { updateProcessedImage(with: activeXMP(for: asset)) }
                        } label: {
                            Text(roiPrototypeEnabled ? "ROI ON · EXP" : "ROI OFF · EXP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(roiPrototypeEnabled ? .black : LightroomTheme.accentYellow)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(roiPrototypeEnabled ? LightroomTheme.accentYellow : Color.black.opacity(0.6))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Native 100% visible-region rendering. In-memory only.")
                        
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
                .onAppear { viewportPixels = viewportSize }
                .onChange(of: viewportSize) { _, newSize in
                    viewportPixels = newSize
                    if roiPrototypeEnabled, inspection.zoomed, let asset = appState.primarySelectedAsset { updateProcessedImage(with: activeXMP(for: asset)) }
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
            if InspectionFrameLayout.canReuseNativeFrame(isNative: display.native, isROI: display.sourceRect != nil, zoomed: is100PercentZoom) && display.owns(assetID: appState.primarySelectedAssetID) && !isLoading && imageError == nil { return }
            if !is100PercentZoom && display.owns(assetID: appState.primarySelectedAssetID) { InspectionFrameLayout.leaveNative(display: &display) }
            InspectionTrace.event(is100PercentZoom ? "state.zoom_onchange_zoomed" : "state.zoom_onchange_fit_render", state: inspection)
            if let asset = appState.primarySelectedAsset { updateProcessedImage(with: activeXMP(for: asset)) }
        }
        .onDisappear {
            inspection.end()
            _ = loadRevision.next()
            _ = renderRevision.next()
            idleFullRenderTask?.cancel()
            finishCurrentROIForeground()
            Task { await PreviewPreloader.shared.cancelForegroundSelection() }
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
    @State private var roiThrottle = InspectionROIThrottle()
    @State private var cachedROITransition = InspectionCachedROITransition()
    @State private var cachedROISelectedPreview: NSImage?
    @State private var roiForeground = InspectionROIForegroundLifecycle()

    private func startROIForeground(owner: String) {
        roiForeground.begin(owner)
        Task { await ProcessedROICacheService.shared.foregroundStarted(owner: owner) }
    }

    private func finishROIForeground(owner: String) {
        guard let released = roiForeground.finish(owner) else { return }
        Task { await ProcessedROICacheService.shared.foregroundFinished(owner: released) }
    }

    private func finishCurrentROIForeground() {
        guard let released = roiForeground.finishCurrent() else { return }
        Task { await ProcessedROICacheService.shared.foregroundFinished(owner: released) }
    }

    @MainActor
    private func loadSelectedImage() async {
        let ticket = loadRevision.next()
        _ = renderRevision.next()
        idleFullRenderTask?.cancel()
        cachedROITransition = InspectionCachedROITransition()
        cachedROISelectedPreview = nil
        imageError = nil
        isLoading = false
        currentBaseHolder = nil
        holderAssetID = nil
        guard let asset = appState.primarySelectedAsset else {
            display = InspectionDisplay()
            finishCurrentROIForeground()
            await PreviewPreloader.shared.foregroundSelectionEnded()
            return
        }
        let targetID = asset.id
        let frameTicket = InspectionLoadTransition.beginSelection(for: asset, display: &display)
        displayTicket = frameTicket
        isLoading = true
        startROIForeground(owner: frameTicket.uuidString)
        await PreviewPreloader.shared.foregroundSelectionStarted(targetID)
        // Decode and thumbnail preparation overlap; native inspection never waits for the thumbnail.
        let thumbnailTask = Task { @MainActor in
            let cached = await PreviewPreloader.shared.cachedPreview(for: asset, maxPixelSize: 1600)
            let thumb: NSImage?
            if let cached {
                thumb = cached
            } else {
                thumb = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 1600)
            }
            guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID,
                  holderAssetID != targetID, (!is100PercentZoom || display.image == nil) else { return }
            if let thumb {
                display.accept(thumb, assetID: targetID, filename: asset.filename, pixels: thumb.size, native: false, ticket: frameTicket)
            }
        }
        defer { thumbnailTask.cancel() }
        let xmp = activeXMP(for: asset)
        if roiPrototypeEnabled, is100PercentZoom,
           let (_, orientation) = ProcessedROIRequest.orientedExtent(for: asset),
           let match = await ProcessedROICacheService.shared.cachedMatch(
                assetID: asset.id, fileVersion: ProcessedROIRequest.fileVersion(for: asset),
                developSettings: ProcessedROIRequest.settingsIdentity(xmp), cameraModel: asset.cameraMetadata.model ?? "",
                center: inspection.center, viewport: viewportPixels, backing: backingScale, orientation: orientation),
           loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID {
            _ = cachedROITransition.publishCachedROI()
            display.accept(match.image, assetID: targetID, filename: asset.filename, pixels: match.identity.sourceRect.size,
                           native: true, ticket: frameTicket, sourceRect: match.identity.sourceRect,
                           fullExtent: match.identity.fullExtent)
            isLoading = false
            imageError = nil
            InspectionTrace.event("render.roi_cache_hit_before_decode", state: inspection)
            finishROIForeground(owner: frameTicket.uuidString)
            scheduleProcessedNeighbors(from: asset)
            // Keep the valid ROI visible while preparing the full-resolution base holder.
            // If the user chooses Fit during this await, the completion schedules that render.
            Task { @MainActor in
                var holderXMP = xmp
                var settingsChangedDuringWarmup = false
                var holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: holderXMP)
                guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
                // Develop edits can change while the holder decode is suspended. Keep the holder
                // and any Fit render aligned with the latest active settings.
                while ProcessedROIRequest.settingsIdentity(activeXMP(for: asset)) != ProcessedROIRequest.settingsIdentity(holderXMP) {
                    settingsChangedDuringWarmup = true
                    holderXMP = activeXMP(for: asset)
                    holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: holderXMP)
                    guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
                }
                guard let holder else {
                    guard cachedROITransition.baseHolderFailed() == .loadFullFitPreview else {
                        await PreviewPreloader.shared.foregroundSelectionCompleted(targetID)
                        return
                    }
                    let preview = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 1600)
                    guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID,
                          let preview else {
                        if loadRevision.accepts(ticket) { imageError = "Unable to load a full preview for \(asset.filename)."; isLoading = false }
                        await PreviewPreloader.shared.foregroundSelectionCompleted(targetID)
                        return
                    }
                    cachedROISelectedPreview = preview
                    guard !is100PercentZoom else { return }
                    display.accept(preview, assetID: targetID, filename: asset.filename, pixels: preview.size,
                                   native: false, ticket: frameTicket)
                    imageError = nil
                    isLoading = false
                    await PreviewPreloader.shared.foregroundSelectionCompleted(targetID)
                    return
                }
                currentBaseHolder = holder
                holderAssetID = targetID
                if cachedROITransition.baseHolderPrepared(isZoomed: is100PercentZoom) == .renderFullFit {
                    updateProcessedImage(with: holderXMP)
                } else if settingsChangedDuringWarmup {
                    updateProcessedImage(with: holderXMP)
                } else if cachedROITransition.shouldCompletePreviewSelectionAfterHolderPreparation(isZoomed: is100PercentZoom) {
                    await PreviewPreloader.shared.foregroundSelectionCompleted(targetID)
                }
            }
            return
        }
        let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: xmp)
        guard !Task.isCancelled, loadRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
        currentBaseHolder = holder
        holderAssetID = targetID
        guard holder != nil else {
            isLoading = false
            imageError = "Unable to decode \(asset.filename). Native 100% unavailable."
            await PreviewPreloader.shared.foregroundSelectionCompleted(targetID)
            finishROIForeground(owner: frameTicket.uuidString)
            return
        }
        updateProcessedImage(with: activeXMP(for: asset))
    }

    private func activeXMP(for asset: PhotoAsset) -> XMPMetadata {
        if appState.liveDevelopAssetID == asset.id, let xmp = appState.liveDevelopXMP { return xmp }
        return asset.xmp
    }

    private func updateProcessedImage(with xmp: XMPMetadata?) {
        let ticket = renderRevision.next()
        InspectionTrace.event("render.revision_issued", state: inspection, requestID: ticket, highFrequency: true)
        if idleFullRenderTask != nil { InspectionTrace.event("render.debounce_cancelled", state: inspection, requestID: ticket, highFrequency: true) }
        idleFullRenderTask?.cancel()
        guard let asset = appState.primarySelectedAsset else { finishCurrentROIForeground(); return }
        guard holderAssetID == asset.id, let holder = currentBaseHolder else {
            if !is100PercentZoom, let preview = cachedROISelectedPreview {
                display.accept(preview, assetID: asset.id, filename: asset.filename, pixels: preview.size,
                               native: false, ticket: displayTicket)
                imageError = nil
                isLoading = false
                return
            }
            if cachedROITransition.needsBaseHolder && !is100PercentZoom { cachedROITransition.requestFit() }
            return
        }
        let targetID = asset.id
        let model = asset.cameraMetadata.model
        let native = is100PercentZoom
        let roiRect = native
            ? InspectionROI.requestRect(enabled: roiPrototypeEnabled, nativeSupported: holder.supportsNativeInspection,
                extent: holder.fullExtent, center: inspection.center, viewport: viewportPixels, backing: backingScale)
            : nil
        InspectionTrace.event(native ? (roiRect == nil ? "render.request_native_full" : "render.request_native_roi") : "render.request_fit", state: inspection, requestID: ticket, highFrequency: roiRect != nil)
        imageError = nil
        guard !native || holder.supportsNativeInspection else {
            isLoading = false
            imageError = "Native 100% unavailable for \(asset.filename). Release or choose Fit for preview."
            Task { await PreviewPreloader.shared.foregroundSelectionCompleted(targetID) }
            finishCurrentROIForeground()
            return
        }
        // Every foreground render (including zoom and develop refreshes) pauses speculation.
        Task { await PreviewPreloader.shared.foregroundSelectionStarted(targetID) }
        let roiOwner = ticket.uuidString
        startROIForeground(owner: roiOwner)
        isLoading = true
        // Preserve the existing fast slider path in Fit; refine only after idle.
        if !native {
            LiveDevelopPreviewEngine.shared.requestRender(
                baseHolder: holder, cameraModel: model, xmp: xmp, interactive: true
            ) { result in
                guard renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else {
                    InspectionTrace.event("render.publication_rejected_stale")
                    return
                }
                if let result { display.accept(result, assetID: targetID, filename: asset.filename, pixels: holder.fullExtent.size, native: false, ticket: displayTicket) }
            }
        }
        idleFullRenderTask = Task { @MainActor in
            if roiRect != nil {
                let due = roiThrottle.dueTime(forRequestAt: ProcessInfo.processInfo.systemUptime)
                InspectionTrace.event("render.roi_throttle_wait", state: inspection, requestID: ticket, highFrequency: true)
                let delay = max(0, due - ProcessInfo.processInfo.systemUptime)
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, renderRevision.accepts(ticket) else { finishROIForeground(owner: roiOwner); return }
            } else {
                roiThrottle.cancelPending()
            }
            if !native {
                InspectionTrace.event("render.fit_debounce_200ms")
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { finishROIForeground(owner: roiOwner); return }
            }
            // Reuse the established RAW decode and color pipeline, including WB.
            let fresh = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: xmp) ?? holder
            guard !Task.isCancelled, renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { finishROIForeground(owner: roiOwner); return }
            currentBaseHolder = fresh
            if roiRect != nil { roiThrottle.submitted(at: ProcessInfo.processInfo.systemUptime) }
            let roiRequest: ProcessedROIRequest? = roiRect.flatMap { rect in
                ProcessedROIRequest.make(asset: asset, xmp: xmp ?? .empty, cameraModel: model, center: inspection.center,
                    viewport: viewportPixels, backing: backingScale,
                    orientation: ProcessedROIRequest.orientedExtent(for: asset)?.1 ?? 1,
                    extent: fresh.fullExtent, sourceRect: rect)
            }
            if let roiRequest, let cached = await ProcessedROICacheService.shared.cached(roiRequest),
               renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID {
                InspectionTrace.event("render.roi_cache_hit", state: inspection, requestID: ticket)
                display.accept(cached.image, assetID: targetID, filename: asset.filename, pixels: roiRequest.identity.sourceRect.size,
                               native: true, ticket: displayTicket, sourceRect: roiRequest.identity.sourceRect,
                               fullExtent: roiRequest.identity.fullExtent)
                isLoading = false
                imageError = nil
                finishROIForeground(owner: roiOwner)
                scheduleProcessedNeighbors(from: asset)
                return
            }
            LiveDevelopPreviewEngine.shared.requestRender(
                baseHolder: fresh, cameraModel: model, xmp: xmp,
                interactive: false, fullResolution: native, sourceRect: roiRect
            ) { result in
                InspectionTrace.event("render.completion_callback", state: inspection, requestID: ticket)
                guard renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else {
                    InspectionTrace.event("render.publication_rejected_stale")
                    return
                }
                InspectionTrace.event("render.publication_accepted", state: inspection, requestID: ticket)
                if result == nil, roiRect != nil {
                    LiveDevelopPreviewEngine.shared.requestRender(baseHolder: fresh, cameraModel: model, xmp: xmp, interactive: false, fullResolution: true) { fallback in
                        guard renderRevision.accepts(ticket), appState.primarySelectedAssetID == targetID else { return }
                        display.accept(fallback, assetID: targetID, filename: asset.filename, pixels: fresh.fullExtent.size, native: true, ticket: displayTicket, fullExtent: fresh.fullExtent)
                        isLoading = false
                        imageError = fallback == nil ? "Unable to render \(asset.filename)." : nil
                        Task { await PreviewPreloader.shared.foregroundSelectionCompleted(targetID) }
                        finishROIForeground(owner: roiOwner)
                    }
                    return
                }
                display.accept(result, assetID: targetID, filename: asset.filename, pixels: roiRect.map(\.size) ?? fresh.fullExtent.size, native: native, ticket: displayTicket, sourceRect: result == nil ? nil : roiRect, fullExtent: fresh.fullExtent)
                isLoading = false
                imageError = result == nil ? "Unable to render \(asset.filename). Choose another photo to continue." : nil
                Task { await PreviewPreloader.shared.foregroundSelectionCompleted(targetID) }
                if let result, let roiRequest {
                    let cg = result.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    if let cg {
                        let entry = ProcessedROIEntry(image: result, identity: roiRequest.identity, costBytes: cg.bytesPerRow * cg.height)
                        Task { await ProcessedROICacheService.shared.insertForeground(entry, owner: roiOwner) }
                        _ = roiForeground.finish(roiOwner)
                        scheduleProcessedNeighbors(from: asset)
                    }
                } else {
                    finishROIForeground(owner: roiOwner)
                }
            }
        }
    }

    @State private var previousROINeighborIndex: Int?
    private func scheduleProcessedNeighbors(from selected: PhotoAsset) {
        let assets = appState.displayedAssets
        guard let index = assets.firstIndex(where: { $0.id == selected.id }) else { return }
        let forward = previousROINeighborIndex.map { index >= $0 } ?? true
        previousROINeighborIndex = index
        let direction = forward ? [1, -1] : [-1, 1]
        let center = inspection.center, viewport = viewportPixels, backing = backingScale
        var requests: [ProcessedROIRequest] = []
        for step in direction {
            let neighborIndex = index + step
            guard assets.indices.contains(neighborIndex) else { continue }
            let neighbor = assets[neighborIndex]
            guard let (extent, orientation) = ProcessedROIRequest.orientedExtent(for: neighbor) else { continue }
            let rect = InspectionROI.sourceRect(extent: extent, center: center, viewport: viewport, backing: backing)
            requests.append(ProcessedROIRequest.make(asset: neighbor, xmp: neighbor.xmp, cameraModel: neighbor.cameraMetadata.model,
                center: center, viewport: viewport, backing: backing, orientation: orientation, extent: extent, sourceRect: rect))
        }
        Task { await ProcessedROICacheService.shared.prioritize(requests) }
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
