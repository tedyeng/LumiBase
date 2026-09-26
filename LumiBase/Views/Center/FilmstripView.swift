import SwiftUI
import AppKit

/// Bottom horizontal thumbnail carousel for Loupe view
public struct FilmstripView: View {
    @ObservedObject var appState: AppState
    
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
            }
            .frame(height: 85)
            .background(LightroomTheme.headerBackground)
            .onChange(of: appState.primarySelectedAssetID) { _, newID in
                if let newID = newID {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
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

private struct FilmstripItemView: View {
    let asset: PhotoAsset
    let isSelected: Bool
    let isPrimary: Bool
    let onSelect: (_ isToggle: Bool, _ isRange: Bool) -> Void
    
    @State private var thumbnail: NSImage?
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black.opacity(0.4)
                if let img = thumbnail {
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
                if asset.xmp.isLoadedFromSidecar {
                    Text("XMP")
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
        .task(id: asset.id) {
            let loaded = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 180)
            await MainActor.run {
                self.thumbnail = loaded
            }
        }
    }
}
