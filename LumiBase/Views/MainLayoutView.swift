import SwiftUI
import AppKit

/// Main 3-column Lightroom-style desktop window layout with keyboard shortcuts
public struct MainLayoutView: View {
    @StateObject private var appState = AppState()
    
    public init() {}
    
    public var body: some View {
        ZStack {
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
            
            // Export Progress Floating HUD
            if appState.isExporting {
                exportProgressHUD
            }
        }
        .environmentObject(appState)
        .background(LightroomTheme.workspaceBackground)
        .navigationTitle("LumiBase v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.0")")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Open Folder Button
                Button {
                    chooseFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open Photo Folder (Cmd+O)")
                
                // Export Button
                Button {
                    appState.exportSelectedPhotos()
                } label: {
                    let count = appState.selectedAssets.count
                    let total = appState.displayedAssets.count
                    let labelText = (count > 1) ? ((count == total) ? "Export All (\(count))" : "Export (\(count))") : "Export"
                    Label(labelText, systemImage: "square.and.arrow.up")
                }
                .help("Export Selected Photos to High-Quality JPEG (Shift+Cmd+E)")
                .disabled(appState.displayedAssets.isEmpty || appState.isExporting)
                
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseOpenFolder"))) { notif in
            if let url = notif.object as? URL {
                appState.openFolder(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseSelectAll"))) { _ in
            appState.selectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseDeselectAll"))) { _ in
            appState.deselectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseExportPhotos"))) { _ in
            appState.exportSelectedPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseExportAllPhotos"))) { _ in
            appState.exportAllPhotos()
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseIncreaseRating"))) { _ in
            appState.increaseRating()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseDecreaseRating"))) { _ in
            appState.decreaseRating()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseFlag"))) { notif in
            if let flag = notif.object as? FlagStatus {
                appState.setFlag(flag)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseDeletePhotos"))) { _ in
            appState.requestDeleteSelectedPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseSyncSettings"))) { _ in
            if appState.selectedAssetIDs.count > 1 {
                appState.showSyncDialog = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseCopySettings"))) { _ in
            if appState.primarySelectedAsset != nil {
                appState.showCopySettingsDialog = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBasePasteSettings"))) { _ in
            appState.pasteDevelopSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseToggleAutoSync"))) { _ in
            appState.toggleAutoSync()
        }
        .sheet(isPresented: $appState.showSyncDialog) {
            SyncSettingsDialogView(
                mode: .synchronize,
                sourceAsset: appState.primarySelectedAsset,
                targetCount: max(0, appState.selectedAssetIDs.count - 1),
                appState: appState,
                onDismiss: { appState.showSyncDialog = false }
            )
        }
        .sheet(isPresented: $appState.showCopySettingsDialog) {
            SyncSettingsDialogView(
                mode: .copy,
                sourceAsset: appState.primarySelectedAsset,
                targetCount: appState.selectedAssetIDs.count,
                appState: appState,
                onDismiss: { appState.showCopySettingsDialog = false }
            )
        }
        .alert(
            deleteAlertTitle,
            isPresented: $appState.showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                appState.cancelDelete()
            }
            Button("Move to Trash", role: .destructive) {
                appState.confirmDeletePendingPhotos()
            }
        } message: {
            Text(deleteAlertMessage)
        }
    }
    
    private var deleteAlertTitle: String {
        let count = appState.pendingDeleteAssets.count
        if count == 1, let name = appState.pendingDeleteAssets.first?.filename {
            return "Move \"\(name)\" to Trash?"
        } else {
            return "Move \(count) Photos to Trash?"
        }
    }
    
    private var deleteAlertMessage: String {
        let count = appState.pendingDeleteAssets.count
        let hasXmp = appState.pendingDeleteAssets.contains { $0.hasSidecarXMP }
        let hasCompanion = appState.pendingDeleteAssets.contains { !$0.companionURLs.isEmpty }
        
        var msg = (count == 1) ?
            "Are you sure you want to move this photo to the Trash?" :
            "Are you sure you want to move these \(count) photos to the Trash?"
        
        var extraNotes: [String] = []
        if hasCompanion {
            extraNotes.append("paired companion JPG files")
        }
        if hasXmp {
            extraNotes.append("corresponding XMP sidecar files")
        }
        
        if !extraNotes.isEmpty {
            let joined = extraNotes.joined(separator: " and ")
            msg += "\nAny \(joined) will also be moved to the Trash."
        }
        return msg
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
    
    private var exportProgressHUD: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .foregroundColor(LightroomTheme.accentYellow)
                    .font(.system(size: 20))
                
                Text("Exporting to JPEG...")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LightroomTheme.textPrimary)
                
                Spacer()
                
                Button("Cancel") {
                    appState.cancelExport()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(LightroomTheme.textMuted)
            }
            
            ProgressView(value: appState.exportProgressFraction)
                .progressViewStyle(.linear)
                .accentColor(LightroomTheme.accentYellow)
            
            HStack {
                Text(appState.exportCurrentFilename)
                    .font(.system(size: 11))
                    .foregroundColor(LightroomTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Text("\(appState.exportCompletedCount) / \(appState.exportTotalCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(LightroomTheme.accentYellow)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(white: 0.12).opacity(0.96))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LightroomTheme.dividerColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 20, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
