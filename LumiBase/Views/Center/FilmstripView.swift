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
            .frame(height: 85)
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

struct FilmstripItemView: View {
    let asset: PhotoAsset
    let isSelected: Bool
    let isPrimary: Bool
    let onSelect: (_ isToggle: Bool, _ isRange: Bool) -> Void
    var onPreview: (NSImage?) -> Void = { _ in }
    
    @State private var thumbnail: NSImage?
    @State private var thumbnailIdentity: String?
    private var previewIdentity: String { ThumbnailLoader.cacheKey(for: asset, maxPixelSize: 180) }
    
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
            .frame(width: 90, height: 65)
            .clipped()
            
            // Flags & ratings overlay
            HStack(spacing: 3) {
                if asset.xmp.isLoadedFromSidecar || asset.xmp.hasDevelopEdits {
                    Text(asset.xmp.hasDevelopEdits ? "Edited" : "XMP")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(2)
                }
                if asset.xmp.flag == .pick {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 7))
                        .foregroundColor(.white)
                }
                if asset.xmp.rating > 0 {
                    Text("\(asset.xmp.rating)★")
                        .font(.system(size: 7, weight: .bold))
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
        .task(id: ThumbnailLoader.cacheKey(for: asset, maxPixelSize: 180)) {
            if let cached = ThumbnailLoader.cachedMemoryThumbnail(for: asset, maxPixelSize: 180) {
                self.thumbnail = cached
                self.thumbnailIdentity = previewIdentity
                onPreview(cached)
            } else {
                thumbnail = nil
                onPreview(nil)
            }
            let loaded = asset.xmp.hasDevelopEdits
                ? await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 180)
                : await ThumbnailLoader.shared.loadCameraPreview(for: asset, maxPixelSize: 180)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.thumbnail = loaded
                self.thumbnailIdentity = previewIdentity
                onPreview(loaded)
            }
        }
    }
}
