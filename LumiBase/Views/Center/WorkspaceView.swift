import SwiftUI

/// Center workspace hosting either the GridView or LoupeView
public struct WorkspaceView: View {
    @ObservedObject var appState: AppState
    
    public var body: some View {
        VStack(spacing: 0) {
            // Top Filter Bar
            TopFilterBarView(appState: appState)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // Center View (Grid or Loupe)
            Group {
                switch appState.viewMode {
                case .grid:
                    GridView(appState: appState)
                case .loupe:
                    LoupeView(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // Bottom Controls Bar
            BottomControlsBarView(appState: appState)
        }
        .background(LightroomTheme.workspaceBackground)
    }
}
