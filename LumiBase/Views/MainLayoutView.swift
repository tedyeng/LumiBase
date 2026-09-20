import SwiftUI
import AppKit

/// Main 3-column Lightroom-style desktop window layout with keyboard shortcuts
public struct MainLayoutView: View {
    @StateObject private var appState = AppState()
    
    public init() {}
    
    public var body: some View {
        HStack(spacing: 0) {
            // 1. Left Navigator & Collections Panel
            if appState.isLeftSidebarVisible {
                LeftSidebarView(appState: appState)
                Divider().background(LightroomTheme.dividerColor)
            }
            
            // 2. Center Workspace (Grid / Loupe + Filmstrip)
            WorkspaceView(appState: appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 3. Right Inspector & Metadata Panel
            if appState.isRightInspectorVisible {
                Divider().background(LightroomTheme.dividerColor)
                RightInspectorView(appState: appState)
            }
        }
        .environmentObject(appState)
        .background(LightroomTheme.workspaceBackground)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Open Folder Button
                Button {
                    chooseFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open Photo Folder (Cmd+O)")
                
                // Toggle Left Sidebar
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.isLeftSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundColor(appState.isLeftSidebarVisible ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                }
                .help("Toggle Left Panel (F7)")
                
                // Toggle Right Inspector
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.isRightInspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundColor(appState.isRightInspectorVisible ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                }
                .help("Toggle Right Panel (F8)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseOpenFolder"))) { notif in
            if let url = notif.object as? URL {
                appState.openFolder(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseNavPrev"))) { _ in
            appState.selectPreviousPhoto()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseNavNext"))) { _ in
            appState.selectNextPhoto()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseRate"))) { notif in
            if let rating = notif.object as? Int {
                appState.setRating(rating)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseFlag"))) { notif in
            if let flag = notif.object as? FlagStatus {
                appState.setFlag(flag)
            }
        }
    }
    
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Folder"
        
        if panel.runModal() == .OK, let url = panel.url {
            appState.openFolder(url: url)
        }
    }
}
