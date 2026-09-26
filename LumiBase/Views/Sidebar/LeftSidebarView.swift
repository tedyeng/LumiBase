import SwiftUI
import AppKit

/// Represents a root location in the file explorer
public struct RootLocation: Identifiable {
    public let id: String
    public let name: String
    public let icon: String
    public let url: URL
    
    public init(name: String, icon: String, url: URL) {
        self.name = name
        self.icon = icon
        self.url = url
        self.id = url.standardizedFileURL.path
    }
}

/// Left panel: File Explorer Folder Tree and Smart Collections (No Color Labels)
public struct LeftSidebarView: View {
    @ObservedObject var appState: AppState
    
    @State private var recentFolders: [URL] = []
    @State private var expandedFolderPaths: Set<String> = []
    
    private let recentFoldersKey = "LumiBase.RecentFolders"
    private let maxRecentFolders = 5
    
    // Quick access system locations and mounted volumes
    private var rootLocations: [RootLocation] {
        var list: [RootLocation] = []
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        
        // 1. User Home Folders
        let pictures = home.appendingPathComponent("Pictures")
        list.append(RootLocation(name: "Pictures", icon: "photo.on.rectangle.angled", url: pictures))
        
        let desktop = home.appendingPathComponent("Desktop")
        list.append(RootLocation(name: "Desktop", icon: "menubar.dock.rectangle", url: desktop))
        
        let docs = home.appendingPathComponent("Documents")
        list.append(RootLocation(name: "Documents", icon: "doc.fill", url: docs))
        
        let downloads = home.appendingPathComponent("Downloads")
        list.append(RootLocation(name: "Downloads", icon: "arrow.down.circle.fill", url: downloads))
        
        list.append(RootLocation(name: "Home (\(home.lastPathComponent))", icon: "house.fill", url: home))
        
        // 2. External Drives & Mounted Volumes
        let fm = FileManager.default
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        if let volumeContents = try? fm.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for vol in volumeContents {
                let name = vol.lastPathComponent
                let resolvedPath = vol.standardizedFileURL.resolvingSymlinksInPath().path
                
                // Filter out system hidden files, Time Machine snapshots, system root symlink, and internal system volumes
                if name.starts(with: ".") ||
                   name.starts(with: "com.apple.TimeMachine") ||
                   name.contains("localsnapshots") ||
                   name == "Macintosh HD" ||
                   name == "Preboot" ||
                   name == "Recovery" ||
                   name == "VM" ||
                   name == "Update" ||
                   resolvedPath == "/" {
                    continue
                }
                
                if !list.contains(where: { $0.url.standardizedFileURL.path == vol.standardizedFileURL.path }) {
                    list.append(RootLocation(name: name, icon: "externaldrive.fill", url: vol))
                }
            }
        }
        
        return list
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(LightroomTheme.accentYellow)
                Text("FILE EXPLORER")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(LightroomTheme.textSecondary)
                Spacer()
                Button {
                    chooseFolder()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LightroomTheme.accentYellow)
                }
                .buttonStyle(.plain)
                .help("Choose and Open Folder (⌘O)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LightroomTheme.headerBackground)
            
            Divider().background(LightroomTheme.dividerColor)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    
                    // 1. Recent / Opened Folders (曾經點擊過的目錄)
                    if !recentFolders.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(LightroomTheme.accentYellow)
                                    .font(.system(size: 10))
                                Text("RECENT FOLDERS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(LightroomTheme.textMuted)
                                Spacer()
                                Button("Clear") {
                                    clearRecentFolders()
                                }
                                .font(.system(size: 9))
                                .foregroundColor(LightroomTheme.textMuted.opacity(0.8))
                                .buttonStyle(.plain)
                                .help("Clear Recent Folders List")
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            
                            ForEach(recentFolders, id: \.path) { url in
                                FolderTreeRow(
                                    url: url,
                                    customName: nil,
                                    icon: "folder.fill",
                                    level: 0,
                                    showFullPath: true,
                                    appState: appState,
                                    expandedFolderPaths: $expandedFolderPaths
                                )
                            }
                        }
                        
                        // 分隔線：將點擊過的目錄與原本電腦磁碟分開
                        Divider().background(LightroomTheme.dividerColor)
                    }
                    
                    // 2. Disks & System Directories (原本電腦的磁碟和目錄)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "internaldrive")
                                .foregroundColor(LightroomTheme.textMuted)
                                .font(.system(size: 10))
                            Text("PLACES & DISKS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(LightroomTheme.textMuted)
                            Spacer()
                            Button {
                                chooseFolder()
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 11))
                                    .foregroundColor(LightroomTheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Choose and Open Folder (⌘O)")
                        }
                        .padding(.horizontal, 12)
                        
                        // Root System Places & Volumes
                        ForEach(rootLocations, id: \.url.path) { loc in
                            FolderTreeRow(
                                url: loc.url,
                                customName: loc.name,
                                icon: loc.icon,
                                level: 0,
                                appState: appState,
                                expandedFolderPaths: $expandedFolderPaths
                            )
                        }
                    }
                    
                    Divider().background(LightroomTheme.dividerColor)
                    
                    // 3. Smart Collections (No Color Labels)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SMART COLLECTIONS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(LightroomTheme.textMuted)
                            .padding(.horizontal, 12)
                        
                        smartCollectionRow(
                            title: "All Photos",
                            icon: "photo.on.rectangle",
                            count: appState.allAssets.count,
                            isSelected: !appState.filterCriteria.isActive,
                            helpText: "Show All Photos"
                        ) {
                            appState.filterCriteria.reset()
                        }
                        
                        smartCollectionRow(
                            title: "Picks (Flagged)",
                            icon: "flag.fill",
                            iconColor: .white,
                            count: appState.allAssets.filter { $0.xmp.flag == .pick }.count,
                            isSelected: appState.filterCriteria.selectedFlag == .pick,
                            helpText: "Show Picked / Flagged Photos (P)"
                        ) {
                            appState.filterCriteria.reset()
                            appState.filterCriteria.selectedFlag = .pick
                        }
                        
                        smartCollectionRow(
                            title: "5 Stars (★★★★★)",
                            icon: "star.fill",
                            iconColor: LightroomTheme.accentYellow,
                            count: appState.allAssets.filter { $0.xmp.rating == 5 }.count,
                            isSelected: appState.filterCriteria.minimumRating == 5 && appState.filterCriteria.ratingExact,
                            helpText: "Show 5-Star Photos (5)"
                        ) {
                            appState.filterCriteria.reset()
                            appState.filterCriteria.minimumRating = 5
                            appState.filterCriteria.ratingExact = true
                        }
                        
                        smartCollectionRow(
                            title: "Rated (>= 1 Star)",
                            icon: "star.leadinghalf.filled",
                            iconColor: LightroomTheme.accentYellow,
                            count: appState.allAssets.filter { $0.xmp.rating >= 1 }.count,
                            isSelected: appState.filterCriteria.minimumRating == 1 && !appState.filterCriteria.ratingExact,
                            helpText: "Show Rated Photos (≥ 1 Star)"
                        ) {
                            appState.filterCriteria.reset()
                            appState.filterCriteria.minimumRating = 1
                            appState.filterCriteria.ratingExact = false
                        }
                        
                        smartCollectionRow(
                            title: "RAW Files Only",
                            icon: "camera.metering.matrix",
                            count: appState.allAssets.filter { $0.isRaw }.count,
                            isSelected: appState.filterCriteria.showRawOnly,
                            helpText: "Show RAW Sensor Files Only"
                        ) {
                            appState.filterCriteria.reset()
                            appState.filterCriteria.showRawOnly = true
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
        .background(LightroomTheme.panelBackground)
        .onAppear {
            loadRecentFolders()
            if let current = appState.currentFolderURL {
                recordRecentFolder(current)
            }
        }
        .onChange(of: appState.currentFolderURL) { _, newFolder in
            if let newFolder = newFolder {
                recordRecentFolder(newFolder)
            }
        }
    }
    
    private func loadRecentFolders() {
        if let paths = UserDefaults.standard.stringArray(forKey: recentFoldersKey) {
            let urls = paths.compactMap { path -> URL? in
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
                return nil
            }
            self.recentFolders = Array(urls.prefix(maxRecentFolders))
        }
    }
    
    private func recordRecentFolder(_ url: URL) {
        let normalizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        var updated = recentFolders.filter { $0.standardizedFileURL.resolvingSymlinksInPath().path != normalizedPath }
        updated.insert(url, at: 0)
        if updated.count > maxRecentFolders {
            updated = Array(updated.prefix(maxRecentFolders))
        }
        self.recentFolders = updated
        saveRecentFolders()
    }
    
    private func saveRecentFolders() {
        let paths = recentFolders.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        UserDefaults.standard.set(paths, forKey: recentFoldersKey)
    }
    
    private func clearRecentFolders() {
        recentFolders.removeAll()
        UserDefaults.standard.removeObject(forKey: recentFoldersKey)
    }
    
    private func smartCollectionRow(
        title: String,
        icon: String,
        iconColor: Color = LightroomTheme.textSecondary,
        count: Int,
        isSelected: Bool,
        helpText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? LightroomTheme.textPrimary : LightroomTheme.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundColor(LightroomTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isSelected ? LightroomTheme.cardSelectedBackground : Color.clear)
            .cornerRadius(4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .help(helpText ?? title)
    }
    
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Folder"
        
        if panel.runModal() == .OK, let url = panel.url {
            recordRecentFolder(url)
            appState.openFolder(url: url)
        }
    }
}

/// Recursive folder tree row for file explorer navigation
private struct FolderTreeRow: View {
    let url: URL
    let customName: String?
    let icon: String
    let level: Int
    var showFullPath: Bool = false
    @ObservedObject var appState: AppState
    @Binding var expandedFolderPaths: Set<String>
    
    @State private var subfolders: [URL] = []
    @State private var hasLoadedSubfolders: Bool = false
    
    private var isExpanded: Bool {
        let key1 = url.standardizedFileURL.resolvingSymlinksInPath().path
        let key2 = url.path
        return expandedFolderPaths.contains(key1) || expandedFolderPaths.contains(key2)
    }
    
    private var isCurrent: Bool {
        guard let current = appState.currentFolderURL else { return false }
        let currentKey = current.standardizedFileURL.resolvingSymlinksInPath().path
        let urlKey = url.standardizedFileURL.resolvingSymlinksInPath().path
        return currentKey == urlKey
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Folder row
            HStack(spacing: 2) {
                // Indentation
                if level > 0 {
                    Spacer()
                        .frame(width: CGFloat(level * 14))
                }
                
                // 1. Expand / Collapse Trigger (Both Chevron Arrow AND Folder Icon)
                Button {
                    toggleExpand()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(LightroomTheme.textMuted)
                            .frame(width: 14, height: 20)
                        
                        Image(systemName: isExpanded ? "folder.fill" : icon)
                            .font(.system(size: 11))
                            .foregroundColor(isCurrent ? LightroomTheme.accentYellow : LightroomTheme.textSecondary)
                            .frame(width: 16, height: 20)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse Folder" : "Expand Folder")
                
                // 2. Folder Name & Full Path (Click to select & open photos, double click to toggle)
                Button {
                    appState.openFolder(url: url)
                    if !isExpanded {
                        toggleExpand()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(customName ?? url.lastPathComponent)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(isCurrent ? LightroomTheme.textPrimary : LightroomTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        if showFullPath {
                            Text(url.path)
                                .font(.system(size: 9))
                                .foregroundColor(isCurrent ? LightroomTheme.textSecondary.opacity(0.85) : LightroomTheme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, showFullPath ? 3 : 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Folder: \(url.path)")
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        toggleExpand()
                    }
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isCurrent ? LightroomTheme.cardSelectedBackground : Color.clear)
            .cornerRadius(4)
            .padding(.horizontal, 6)
            
            // Subfolders (if expanded)
            if isExpanded {
                ForEach(subfolders, id: \.path) { subURL in
                    FolderTreeRow(
                        url: subURL,
                        customName: nil,
                        icon: "folder",
                        level: level + 1,
                        showFullPath: false,
                        appState: appState,
                        expandedFolderPaths: $expandedFolderPaths
                    )
                }
            }
        }
        .onAppear {
            if isExpanded {
                loadSubfolders()
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                loadSubfolders()
            }
        }
    }
    
    private func toggleExpand() {
        let key1 = url.standardizedFileURL.resolvingSymlinksInPath().path
        let key2 = url.path
        if isExpanded {
            expandedFolderPaths.remove(key1)
            expandedFolderPaths.remove(key2)
        } else {
            expandedFolderPaths.insert(key1)
            expandedFolderPaths.insert(key2)
            loadSubfolders()
        }
    }
    
    private func loadSubfolders() {
        let targetURL = url
        let hasAccess = targetURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            hasLoadedSubfolders = true
            subfolders = []
            return
        }
        
        guard let contents = try? fm.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else {
            hasLoadedSubfolders = true
            subfolders = []
            return
        }
        
        let filtered = contents.filter { itemURL in
            var itemIsDir: ObjCBool = false
            if fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir), itemIsDir.boolValue {
                let name = itemURL.lastPathComponent
                // Filter out system, library, trash, app packages
                if name.starts(with: ".") || name == "Library" || name == "$RECYCLE.BIN" || name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") {
                    return false
                }
                return true
            }
            return false
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        self.subfolders = filtered
        self.hasLoadedSubfolders = true
    }
}
