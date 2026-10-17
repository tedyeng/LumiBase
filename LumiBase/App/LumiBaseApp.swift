import SwiftUI

@main
struct LumiBaseApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceReopenDelegate.self) private var appDelegate
    init() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        } else if let assetIcon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = assetIcon
        }
    }
    
    private var appTitleWithVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.14.15"
        return "LumiBase v\(version)"
    }
    
    var body: some Scene {
        // SwiftUI uses the first scene for launch and standard Dock/Finder reopen.
        // Settings must not be the default scene or no workspace is created.
        WindowGroup(appTitleWithVersion, id: "workspace") {
            MainLayoutView()
                .background(WorkspaceReopenRegistration(delegate: appDelegate, isWorkspace: true))
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .navigationTitle(appTitleWithVersion)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseOpenFolder"), object: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Divider()
                
                Button("Export Selected Photos...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseExportPhotos"), object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                
                Button("Export All Photos...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseExportAllPhotos"), object: nil)
                }
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Select All") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseSelectAll"), object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
                
                Button("Deselect All") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseDeselectAll"), object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                
                Divider()
                
                Button("Find Photos...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFocusSearch"), object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                
                Divider()
                
                Button("Move to Trash...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseDeletePhotos"), object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandMenu("Photo") {
                Button("Previous Photo") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseNavPrev"), object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                
                Button("Next Photo") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseNavNext"), object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                
                Divider()
                
                Button("Set 5 Stars") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRate"), object: 5) }.keyboardShortcut("5", modifiers: [])
                Button("Set 4 Stars") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRate"), object: 4) }.keyboardShortcut("4", modifiers: [])
                Button("Set 3 Stars") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRate"), object: 3) }.keyboardShortcut("3", modifiers: [])
                Button("Set 2 Stars") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRate"), object: 2) }.keyboardShortcut("2", modifiers: [])
                Button("Set 1 Star") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRate"), object: 1) }.keyboardShortcut("1", modifiers: [])
                Button("Clear Rating") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRate"), object: 0) }.keyboardShortcut("0", modifiers: [])
                
                Divider()
                
                Button("Increase Rating") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseIncreaseRating"), object: nil) }.keyboardShortcut("]", modifiers: [])
                Button("Decrease Rating") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseDecreaseRating"), object: nil) }.keyboardShortcut("[", modifiers: [])
                
                Divider()
                
                Button("Flag as Pick") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlag"), object: FlagStatus.pick) }.keyboardShortcut("p", modifiers: [])
                Button("Flag as Reject") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlag"), object: FlagStatus.reject) }.keyboardShortcut("x", modifiers: [])
                Button("Unflag") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlag"), object: FlagStatus.unflagged) }.keyboardShortcut("u", modifiers: [])
                
                Divider()
                
                Button("Reload XMP from Disk") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseReloadXMP"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Develop") {
                Button("Edit Adjustments") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseEditTool"), object: nil)
                }
                .keyboardShortcut("e", modifiers: [])
                
                Button("Crop & Straighten") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseCropTool"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [])
                
                Divider()
                
                Button("Toggle Before / After") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleBeforeAfter"), object: nil)
                }
                .keyboardShortcut("\\", modifiers: [])
                
                Button("Cycle Comparison Mode") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseCycleComparison"), object: nil)
                }
                .keyboardShortcut("y", modifiers: [])
                
                Divider()
                
                Button("Auto Tone") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseAutoTone"), object: nil)
                }
                
                Button("Toggle Treatment (Color / B&W)") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleBW"), object: nil)
                }
                
                Divider()
                
                Button("Flip Crop Orientation") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlipCrop"), object: nil)
                }
                .keyboardShortcut("x", modifiers: [])
                
                Button("Cycle Crop Overlay Guide") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseCycleOverlay"), object: nil)
                }
                .keyboardShortcut("o", modifiers: [])
                
                Button("Reset Crop") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseResetCrop"), object: nil)
                }
                
                Divider()
                
                Button("Copy Settings...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseCopySettings"), object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                
                Button("Paste Settings") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBasePasteSettings"), object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Sync Settings...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseSyncSettings"), object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                
                Button("Toggle Auto Sync") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleAutoSync"), object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                
                Divider()
                
                Button("Reset All Adjustments") {
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseResetDevelop"), object: nil)
                }
            }
        }
        Settings {
            PerformanceSettingsView(settings: .shared)
                .background(WorkspaceReopenRegistration(delegate: appDelegate, isWorkspace: false))
        }
    }
}

/// A visible Settings window is not a workspace. Only an explicit Dock/Finder
/// reopen requests the workspace; ordinary activation never creates a window.
@MainActor final class WorkspaceReopenDelegate: NSObject, NSApplicationDelegate {
    var openWorkspace: (() -> Void)?
    private var opening = false
    private var hasPresentedWorkspace = false
    private let workspaceWindows = NSHashTable<NSWindow>.weakObjects()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The initial LaunchServices open can arrive before SwiftUI creates its
        // default scene. Let launch finish instead of requesting a second scene.
        guard hasPresentedWorkspace else { return true }
        if let window = sender.windows.first(where: { workspaceWindows.contains($0) }) {
            window.makeKeyAndOrderFront(nil)
        } else if !opening, let openWorkspace {
            opening = true
            openWorkspace()
        }
        return false
    }

    func registeredWorkspace(_ window: NSWindow? = nil) {
        if let window { workspaceWindows.add(window) }
        hasPresentedWorkspace = true
        opening = false
    }
}

private struct WorkspaceReopenRegistration: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let delegate: WorkspaceReopenDelegate
    let isWorkspace: Bool

    final class Surface: NSView {
        var register: ((NSWindow) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register?(window) }
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        delegate.openWorkspace = { openWindow(id: "workspace") }
        view.register = { window in
            guard isWorkspace else { return }
            delegate.registeredWorkspace(window)
        }
        if let window = view.window { view.register?(window) }
    }
}
