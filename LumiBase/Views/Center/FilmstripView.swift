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
                        let isSelected = appState.primarySelectedAssetID == asset.id
                        
                        FilmstripItemView(
                            asset: asset,
                            isSelected: isSelected,
                            onSelect: {
                                appState.selectAsset(asset)
                            }
                        )
                        .id(asset.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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

private struct FilmstripItemView: View {
    let asset: PhotoAsset
    let isSelected: Bool
    let onSelect: () -> Void
    
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
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? LightroomTheme.accentYellow : LightroomTheme.cardBorder, lineWidth: isSelected ? 2 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .task(id: asset.id) {
            let loaded = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 180)
            await MainActor.run {
                self.thumbnail = loaded
            }
        }
    }
}
