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
                        .uiFont(13)
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
                        .uiFont(13)
                        .foregroundColor(appState.viewMode == .loupe ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                        .padding(5)
                        .background(appState.viewMode == .loupe ? LightroomTheme.cardSelectedBackground : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Loupe View (E)")
                
                if appState.viewMode == .loupe && appState.workspaceMode == .develop {
                    Menu {
                        Button {
                            appState.comparisonMode = .off
                            appState.isBeforeToggled = false
                        } label: {
                            Text("Single Image (After)")
                        }
                        Button {
                            appState.toggleBeforeAfter()
                        } label: {
                            Text("Toggle Before / After")
                        }
                        .keyboardShortcut("\\", modifiers: [])
                        
                        Divider()
                        
                        Button {
                            appState.comparisonMode = .splitLeftRight
                            appState.isBeforeToggled = false
                        } label: {
                            Text("Left / Right Split")
                        }
                        .keyboardShortcut("y", modifiers: [])
                        
                        Button {
                            appState.comparisonMode = .sideBySide
                            appState.isBeforeToggled = false
                        } label: {
                            Text("Side-by-Side")
                        }
                        .keyboardShortcut("y", modifiers: .shift)
                        
                        Button {
                            appState.comparisonMode = .splitTopBottom
                            appState.isBeforeToggled = false
                        } label: {
                            Text("Top / Bottom Split")
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: appState.comparisonMode == .off ? (appState.isBeforeToggled ? "clock.arrow.circlepath" : "rectangle.split.2x1") : appState.comparisonMode.iconName)
                                .uiFont(12)
                            Image(systemName: "chevron.up.chevron.down")
                                .uiFont(8)
                        }
                        .foregroundColor((appState.comparisonMode != .off || appState.isBeforeToggled) ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                        .padding(5)
                        .background((appState.comparisonMode != .off || appState.isBeforeToggled) ? LightroomTheme.cardSelectedBackground : Color.clear)
                        .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Before / After Comparison View (Y / \\)")
                }
            }
            
            Divider()
                .frame(height: 14)
                .background(LightroomTheme.dividerColor)
            
            // Sort Order Picker
            HStack(spacing: 6) {
                Text("Sort:")
                    .uiFont(11)
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
                        .uiFont(11)
                        .foregroundColor(LightroomTheme.accentYellow)
                } else {
                    Text(appState.photoPositionLabel)
                        .uiFont(11)
                        .foregroundColor(LightroomTheme.textSecondary)
                }
            }
            
            Divider()
                .frame(height: 14)
                .background(LightroomTheme.dividerColor)
            
            // Thumbnail Zoom Slider
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .uiFont(9)
                    .foregroundColor(LightroomTheme.textMuted)
                
                Slider(value: $appState.thumbnailSize, in: 120...420, step: 10)
                    .frame(width: 100)
                    .accentColor(LightroomTheme.accentYellow)
                    .help("Adjust Grid Thumbnail Size")
                
                Image(systemName: "photo")
                    .uiFont(14)
                    .foregroundColor(LightroomTheme.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(LightroomTheme.headerBackground)
    }
}
