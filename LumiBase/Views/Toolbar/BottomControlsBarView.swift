import SwiftUI

/// Lightroom-style bottom toolbar with view switchers (Grid/Loupe), zoom slider, sort order, and asset counts
public struct BottomControlsBarView: View {
    @ObservedObject var appState: AppState
    
    public var body: some View {
        HStack(spacing: 16) {
            
            // View Mode Switcher: Grid (G) vs Loupe (E)
            HStack(spacing: 2) {
                Button {
                    appState.viewMode = .grid
                } label: {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 13))
                        .foregroundColor(appState.viewMode == .grid ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                        .padding(5)
                        .background(appState.viewMode == .grid ? LightroomTheme.cardSelectedBackground : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Grid View (G)")
                
                Button {
                    appState.viewMode = .loupe
                } label: {
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 13))
                        .foregroundColor(appState.viewMode == .loupe ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                        .padding(5)
                        .background(appState.viewMode == .loupe ? LightroomTheme.cardSelectedBackground : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Loupe View (E)")
            }
            
            Divider()
                .frame(height: 14)
                .background(LightroomTheme.dividerColor)
            
            // Sort Order Picker
            HStack(spacing: 6) {
                Text("Sort:")
                    .font(.system(size: 11))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                Picker("", selection: $appState.sortOrder) {
                    ForEach(AssetSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                .labelsHidden()
                .help("Change Photo Sort Order")
            }
            
            Spacer()
            
            // Photo Counter / Selection Status
            HStack(spacing: 4) {
                if appState.isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text(appState.scanProgressMessage)
                        .font(.system(size: 11))
                        .foregroundColor(LightroomTheme.accentYellow)
                } else {
                    let total = appState.allAssets.count
                    let filtered = appState.displayedAssets.count
                    let selected = appState.selectedAssetIDs.count
                    
                    if selected > 1 {
                        Text("\(selected) of \(filtered) selected")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(LightroomTheme.accentYellow)
                    } else if filtered < total {
                        Text("\(filtered) of \(total) photos (Filtered)")
                            .font(.system(size: 11))
                            .foregroundColor(LightroomTheme.textSecondary)
                    } else {
                        Text("\(total) photos")
                            .font(.system(size: 11))
                            .foregroundColor(LightroomTheme.textSecondary)
                    }
                }
            }
            
            Divider()
                .frame(height: 14)
                .background(LightroomTheme.dividerColor)
            
            // Thumbnail Zoom Slider
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundColor(LightroomTheme.textMuted)
                
                Slider(value: $appState.thumbnailSize, in: 120...420, step: 10)
                    .frame(width: 100)
                    .accentColor(LightroomTheme.accentYellow)
                    .help("Adjust Grid Thumbnail Size")
                
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(LightroomTheme.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(LightroomTheme.headerBackground)
    }
}
