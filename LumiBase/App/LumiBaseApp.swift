import SwiftUI

@main
struct LumiBaseApp: App {
    init() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        } else if let assetIcon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = assetIcon
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MainLayoutView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
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
                
                Button("Flag as Pick") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlag"), object: FlagStatus.pick) }.keyboardShortcut("p", modifiers: [])
                Button("Flag as Reject") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlag"), object: FlagStatus.reject) }.keyboardShortcut("x", modifiers: [])
                Button("Unflag") { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseFlag"), object: FlagStatus.unflagged) }.keyboardShortcut("u", modifiers: [])
            }
        }
    }
}
