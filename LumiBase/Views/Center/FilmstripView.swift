import SwiftUI
import AppKit

/// Bottom horizontal thumbnail carousel for Loupe view
public struct FilmstripView: View {
    @ObservedObject var appState: AppState
    @State private var hasLaidOutContent = false

    // Share the grid's explicit-active/visible-collection validation, never a
    // fallback member of multi-selection or the first unfiltered photo.
    private var activeScrollTargetID: String? { appState.gridScrollTargetID }

    private func restoreActivePhoto(using proxy: ScrollViewProxy) {
        // One main-loop turn lets the lazy stack register its destinations.
        DispatchQueue.main.async {
            guard hasLaidOutContent, appState.viewMode == .loupe,
                  appState.isFilmstripVisible, let id = activeScrollTargetID else { return }
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(appState.displayedAssets) { asset in
                        let isSelected = appState.selectedAssetIDs.contains(asset.id)
                        let isPrimary = appState.primarySelectedAssetID == asset.id
                        
                        FilmstripItemView(
                            asset: asset,
                            itemHeight: max(40, appState.filmstripHeight - 20),
                            isSelected: isSelected,
                            isPrimary: isPrimary,
                            onSelect: { isToggle, isRange in
                                appState.selectAsset(asset, isToggle: isToggle, isRange: isRange)
                            }
                        )
                        .id(asset.id)
                        .contextMenu {
                            if !appState.selectedAssets.isEmpty {
                                Button("Export Selected (\(appState.selectedAssets.count)) to JPEG... (⇧⌘E)") {
                                    appState.exportPhotos(assets: appState.selectedAssets)
                                }
                            }
                            Button("Export All (\(appState.displayedAssets.count)) Images...") {
                                appState.exportPhotos(assets: appState.displayedAssets)
                            }
                            if appState.selectedAssetIDs.count >= 2 {
                                Button("Merge \(appState.selectedAssetIDs.count) Photos to Panorama (DNG)... (⌃⌘P)") {
                                    appState.showPanoramaDialog = true
                                }
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
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(FilmstripWheelBridge())
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    guard !hasLaidOutContent, size.width > 0, size.height > 0 else { return }
                    hasLaidOutContent = true
                    // Restore only once per mount, not on later lazy layouts or wheel scrolling.
                    restoreActivePhoto(using: proxy)
                }
            }
            .frame(height: appState.filmstripHeight)
            .background(PhotoKeyboardFocusSurface(appState: appState))
            .background(LightroomTheme.headerBackground)
            .onChange(of: activeScrollTargetID) { _, _ in
                restoreActivePhoto(using: proxy)
            }
            .onChange(of: appState.viewMode) { _, mode in
                if mode == .loupe { restoreActivePhoto(using: proxy) }
            }
            .onChange(of: appState.isFilmstripVisible) { _, visible in
                if visible { restoreActivePhoto(using: proxy) }
            }
            .onChange(of: appState.filterCriteria) { _, _ in
                restoreActivePhoto(using: proxy)
            }
            .onChange(of: appState.sortOrder) { _, _ in
                restoreActivePhoto(using: proxy)
            }
            .onChange(of: appState.isScanning) { _, scanning in
                if !scanning { restoreActivePhoto(using: proxy) }
            }
        }
    }
}

/// A non-hit-testing bridge inside the document, scoped to its enclosing scroll
/// view's visible viewport. It never observes keys or consumes a held image drag.
struct FilmstripWheelBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> FilmstripWheelView { FilmstripWheelView() }
    func updateNSView(_ view: FilmstripWheelView, context: Context) {}
    static func dismantleNSView(_ view: FilmstripWheelView, coordinator: ()) { view.stopMonitoring() }
}

final class FilmstripWheelView: NSView {
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.route(event, pressedButtons: NSEvent.pressedMouseButtons)
            }
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    func route(_ event: NSEvent, pressedButtons: Int) -> NSEvent? {
        guard event.type == .scrollWheel, pressedButtons == 0,
              let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              let scroll = enclosingScrollView,
              scroll.contentView.bounds.contains(scroll.contentView.convert(event.locationInWindow, from: nil)),
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
        let clip = scroll.contentView
        let maximum = max(0, (scroll.documentView?.bounds.width ?? 0) - clip.bounds.width)
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 24)
        var origin = clip.bounds.origin
        origin.x = min(maximum, max(0, origin.x - delta))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return nil
    }
}

/// Draggable divider above the bottom filmstrip to resize thumbnail height.
public struct FilmstripResizeHandle: View {
    @ObservedObject var appState: AppState
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat?
    @State private var hasPushedCursor = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(isDragging || isHovering ? LightroomTheme.accentYellow.opacity(0.7) : LightroomTheme.dividerColor)
                .frame(height: isDragging || isHovering ? 2 : 1)

            if isDragging || isHovering {
                Capsule()
                    .fill(LightroomTheme.accentYellow)
                    .frame(width: 36, height: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering && !hasPushedCursor {
                NSCursor.resizeUpDown.push()
                hasPushedCursor = true
            } else if !hovering && !isDragging && hasPushedCursor {
                NSCursor.pop()
                hasPushedCursor = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = appState.filmstripHeight
                    }
                    isDragging = true
                    if !hasPushedCursor {
                        NSCursor.resizeUpDown.push()
                        hasPushedCursor = true
                    }
                    let base = dragStartHeight ?? appState.filmstripHeight
                    appState.filmstripHeight = AppState.clampFilmstripHeight(base - value.translation.height)
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartHeight = nil
                    if !isHovering && hasPushedCursor {
                        NSCursor.pop()
                        hasPushedCursor = false
                    }
                }
        )
        .onTapGesture(count: 2) {
            appState.filmstripHeight = AppState.defaultFilmstripHeight
        }
        .onDisappear {
            if hasPushedCursor {
                NSCursor.pop()
                hasPushedCursor = false
            }
        }
        .help("Drag to resize filmstrip thumbnails (Double-click to reset)")
    }
}

struct FilmstripItemView: View {
    let asset: PhotoAsset
    var itemHeight: CGFloat = 65
    let isSelected: Bool
    let isPrimary: Bool
    let onSelect: (_ isToggle: Bool, _ isRange: Bool) -> Void
    var onPreview: (NSImage?) -> Void = { _ in }
    
    @State private var thumbnail: NSImage?
    @State private var thumbnailIdentity: String?
    private var itemWidth: CGFloat { round(itemHeight * (90.0 / 65.0)) }
    private var requestedPixelSize: Int {
        itemHeight <= 80 ? 180 : (itemHeight <= 130 ? 300 : 440)
    }
    private var previewIdentity: String { ThumbnailLoader.cacheKey(for: asset, maxPixelSize: requestedPixelSize) }
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black.opacity(0.4)
                if thumbnailIdentity == previewIdentity, let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().scaleEffect(0.5)
                }
                
                // Subtle highlight overlay for multi-selected items
                if isSelected && !isPrimary {
                    Color.white.opacity(0.18)
                }
            }
            .frame(width: itemWidth, height: itemHeight)
            .clipped()
            
            // Top-left filename overlay
            .overlay(alignment: .topLeading) {
                Text(asset.filename)
                    .uiFont(7, weight: .medium)
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(2)
                    .frame(maxWidth: max(20, itemWidth - 6), alignment: .leading)
                    .padding(3)
            }
            
            // Flags & ratings overlay
            HStack(spacing: 3) {
                if asset.xmp.isLoadedFromSidecar || asset.xmp.hasDevelopEdits {
                    let isEdited = asset.xmp.hasDevelopEdits
                    Text(isEdited ? "Edited" : "XMP")
                        .uiFont(6, weight: .bold)
                        .foregroundColor(isEdited ? .green : .cyan)
                        .padding(.horizontal, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(2)
                }
                if asset.xmp.flag == .pick {
                    Image(systemName: "flag.fill")
                        .uiFont(7)
                        .foregroundColor(.white)
                }
                if asset.xmp.rating > 0 {
                    Text("\(asset.xmp.rating)★")
                        .uiFont(7, weight: .bold)
                        .foregroundColor(LightroomTheme.accentYellow)
                }
            }
            .padding(3)
        }
        .opacity(isSelected || isPrimary ? 1.0 : 0.65)
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    isPrimary ? LightroomTheme.accentYellow :
                    (isSelected ? Color.white.opacity(0.9) : LightroomTheme.cardBorder),
                    lineWidth: isPrimary ? 2.5 : (isSelected ? 2.0 : 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            let isToggle = flags.contains(.control) || flags.contains(.command)
            let isRange = flags.contains(.shift)
            onSelect(isToggle, isRange)
        }
        .task(id: previewIdentity) {
            let maxPixelSize = requestedPixelSize
            if let cached = ThumbnailLoader.cachedMemoryThumbnail(for: asset, maxPixelSize: maxPixelSize) {
                self.thumbnail = cached
                self.thumbnailIdentity = previewIdentity
                onPreview(cached)
            } else {
                thumbnail = nil
                onPreview(nil)
            }
            let loaded = asset.xmp.hasDevelopEdits
                ? await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: maxPixelSize)
                : await ThumbnailLoader.shared.loadCameraPreview(for: asset, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.thumbnail = loaded
                self.thumbnailIdentity = previewIdentity
                onPreview(loaded)
            }
        }
    }
}
