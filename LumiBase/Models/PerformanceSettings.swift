import SwiftUI

public enum HighlightPreviewQuality: Int, CaseIterable, Identifiable, Sendable {
    case fast = 0
    case full = 1
    
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .fast: return "Fast (Screen-res / Default)"
        case .full: return "Full Resolution (Accurate)"
        }
    }
}

@MainActor final class PerformanceSettings: ObservableObject {
    static let shared = PerformanceSettings()
    public nonisolated static var currentHighlightPreviewQuality: HighlightPreviewQuality {
        let savedQuality = UserDefaults.standard.object(forKey: "highlightPreviewQuality") as? Int ?? HighlightPreviewQuality.fast.rawValue
        return HighlightPreviewQuality(rawValue: savedQuality) ?? .fast
    }
    private let defaults: UserDefaults
    private let cache: LibraryJPEGROICache
    @Published var sharpnessEnabled: Bool {
        didSet { defaults.set(sharpnessEnabled, forKey: "previewSharpnessEnabled") }
    }
    @Published var roiRadius: Int {
        didSet {
            let value = min(2, max(0, roiRadius))
            if roiRadius != value { roiRadius = value }
            defaults.set(value, forKey: "libraryJPEGROIRadius")
            apply()
        }
    }
    @Published var cacheBudgetMiB: Int {
        didSet {
            let value = [64, 128, 256].contains(cacheBudgetMiB) ? cacheBudgetMiB : 64
            if cacheBudgetMiB != value { cacheBudgetMiB = value }
            defaults.set(value, forKey: "libraryJPEGROIBudgetMiB")
            apply()
        }
    }
    @Published var highlightPreviewQuality: HighlightPreviewQuality {
        didSet {
            defaults.set(highlightPreviewQuality.rawValue, forKey: "highlightPreviewQuality")
            RAWImageLoader.shared.clearCache()
            NativeHighlightsService.shared.clear()
            NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRefreshHighlights"), object: nil)
        }
    }
    init(defaults: UserDefaults = .standard, cache: LibraryJPEGROICache = .shared) {
        self.defaults = defaults
        self.cache = cache
        sharpnessEnabled = defaults.bool(forKey: "previewSharpnessEnabled")
        roiRadius = min(2, max(0, defaults.integer(forKey: "libraryJPEGROIRadius")))
        let saved = defaults.integer(forKey: "libraryJPEGROIBudgetMiB")
        cacheBudgetMiB = [64, 128, 256].contains(saved) ? saved : 64
        let savedQuality = defaults.object(forKey: "highlightPreviewQuality") as? Int ?? HighlightPreviewQuality.fast.rawValue
        highlightPreviewQuality = HighlightPreviewQuality(rawValue: savedQuality) ?? .fast
        apply()
    }
    private func apply() {
        cache.configure(budget: cacheBudgetMiB * 1024 * 1024, maxEntries: roiRadius * 2)
    }
    func clearCache() { cache.cancel(clear: true) }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case library = "Library"
    case rendering = "Rendering"
    case general = "General"
    
    var id: String { rawValue }
}

struct PerformanceSettingsView: View {
    @ObservedObject var settings: PerformanceSettings
    @State private var selectedTab: SettingsTab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            libraryTab
                .tabItem {
                    Label("Library & Cache", systemImage: "internaldrive")
                }
                .tag(SettingsTab.library)
            
            renderingTab
                .tabItem {
                    Label("Rendering & RAW", systemImage: "camera.filters")
                }
                .tag(SettingsTab.rendering)
            
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
        }
        .padding(12)
        .frame(width: 560, height: 500)
        .background(SettingsEscapeSurface())
    }
    
    private var libraryTab: some View {
        Form {
            Section("Library JPEG ROI — Experimental Neighbor Cache") {
                Picker("Neighbor preload", selection: $settings.roiRadius) {
                    Text("OFF (default)").tag(0)
                    Text("Previous / next 1").tag(1)
                    Text("Previous / next 2").tag(2)
                }
                .accessibilityIdentifier("libraryROIRadius")
                
                Picker("ROI cache budget", selection: $settings.cacheBudgetMiB) {
                    ForEach([64, 128, 256], id: \.self) { Text("\($0) MiB").tag($0) }
                }
                .accessibilityIdentifier("libraryROIBudget")
                
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text("\(LibraryJPEGROICache.shared.entryCount) entries · \(LibraryJPEGROICache.shared.bytes / 1024 / 1024) MiB cached")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                Button("Clear ROI cache") { settings.clearCache() }
                    .accessibilityIdentifier("clearLibraryROICache")
                
                Text("Only Library JPEG inspection at 100%. No Grid/Fit or Develop RAW neighbor decoding. Choices are remembered. The byte budget includes ROI pixels and reduced fallbacks, not app + helper RSS. Full JPEG decoding has a transient memory peak; warm native hits may be faster. One utility helper at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    private var renderingTab: some View {
        Form {
            Section("RAW Highlight Recovery Preview Quality") {
                Picker("Preview quality", selection: $settings.highlightPreviewQuality) {
                    ForEach(HighlightPreviewQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .accessibilityIdentifier("highlightPreviewQuality")
                
                Text("Fast (Default): Uses fast draft demosaicing and screen-resolution proxies (2560px) during regular viewport inspection and live slider adjustments for instant, fluid 120fps performance on Apple Silicon. Full 1:1 inspection and JPEG exports always use 100% native resolution.\n\nFull Resolution: Always performs multi-exposure RAW demosaicing and guided filtering across the entire full-frame sensor grid, even for scaled viewports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Sharpness / Full Resolution — Experimental") {
                Toggle("Show full-resolution sharpness score (default OFF)", isOn: $settings.sharpnessEnabled)
                    .accessibilityIdentifier("previewSharpnessEnabled")
                
                Text("Relative native-pixel metric: sharpest 10% of 64px Laplacian blocks across the selected full frame. Edited photos use the full processed output including crop, never a viewport ROI. May add a selected full JPEG decode or accurate RAW decode/render, CPU and transient RAM. One active job plus latest pending metadata; no folder preload. Compare the same source/edits. Noise and sharpening bias scores; not focus confidence or an automatic reject rule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    private var generalTab: some View {
        Form {
            Section("Viewer & Overlays") {
                Toggle("Show histogram in Loupe view", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "displayHistogramEnabled") },
                    set: {
                        UserDefaults.standard.set($0, forKey: "displayHistogramEnabled")
                        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseHistogramToggled"), object: nil)
                    }
                ))
                Text("Displays live RGB and luminance histogram overlay in the single photo Loupe view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Window-scoped Escape handling; preserve native editor and tracking-menu cancellation.
private struct SettingsEscapeSurface: NSViewRepresentable {
    final class Surface: NSView {
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var trackingMenus = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus + (name == NSMenu.didBeginTrackingNotification ? 1 : -1))
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      window.attachedSheet == nil, self.trackingMenus == 0 else { return event }
                if window.firstResponder is NSTextView || window.firstResponder is NSTextField { return event }
                window.performClose(nil)
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll(); trackingMenus = 0
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.removeMonitor() }
}
