import SwiftUI

public enum SyncDialogMode {
    case synchronize
    case copy
    
    public var title: String {
        switch self {
        case .synchronize: return "Synchronize Settings"
        case .copy: return "Copy Settings"
        }
    }
    
    public var actionButtonTitle: String {
        switch self {
        case .synchronize: return "Synchronize"
        case .copy: return "Copy"
        }
    }
    
    public var iconName: String {
        switch self {
        case .synchronize: return "arrow.triangle.2.circlepath"
        case .copy: return "doc.on.doc"
        }
    }
}

/// Lightroom Classic-style Synchronize / Copy Develop Settings Dialog
public struct SyncSettingsDialogView: View {
    public let mode: SyncDialogMode
    public let sourceAsset: PhotoAsset?
    public let targetCount: Int
    @ObservedObject var appState: AppState
    public let onDismiss: () -> Void
    
    @State private var options: DevelopSyncOptions = .default
    
    public init(
        mode: SyncDialogMode,
        sourceAsset: PhotoAsset?,
        targetCount: Int,
        appState: AppState,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.sourceAsset = sourceAsset
        self.targetCount = targetCount
        self.appState = appState
        self.onDismiss = onDismiss
        _options = State(initialValue: appState.lastSyncOptions)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(LightroomTheme.accentYellow)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(LightroomTheme.textPrimary)
                    
                    if mode == .synchronize {
                        if let source = sourceAsset {
                            Text("From: \(source.filename) → \(targetCount) other selected photo\(targetCount > 1 ? "s" : "")")
                                .font(.system(size: 11))
                                .foregroundColor(LightroomTheme.textSecondary)
                        } else {
                            Text("Apply settings to \(targetCount) selected photos")
                                .font(.system(size: 11))
                                .foregroundColor(LightroomTheme.textSecondary)
                        }
                    } else {
                        if let source = sourceAsset {
                            Text("Copy adjustments from: \(source.filename)")
                                .font(.system(size: 11))
                                .foregroundColor(LightroomTheme.textSecondary)
                        } else {
                            Text("Select adjustments to copy")
                                .font(.system(size: 11))
                                .foregroundColor(LightroomTheme.textSecondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LightroomTheme.headerBackground)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // Content Sections: 2-column grid
            HStack(alignment: .top, spacing: 16) {
                // Column 1: White Balance & Basic Tone
                VStack(alignment: .leading, spacing: 14) {
                    // White Balance Section
                    categoryBox(title: "WHITE BALANCE") {
                        checkboxRow(title: "White Balance (Temp & Tint)", isOn: $options.whiteBalance)
                    }
                    
                    // Basic Tone Section
                    categoryBox(title: "BASIC TONE", headerTrailing: {
                        toggleAllButton(isOn: options.allToneEnabled) {
                            let target = !options.allToneEnabled
                            options.setAllTone(target)
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            checkboxRow(title: "Exposure", isOn: $options.exposure)
                            checkboxRow(title: "Contrast", isOn: $options.contrast)
                            checkboxRow(title: "Highlights", isOn: $options.highlights)
                            checkboxRow(title: "Shadows", isOn: $options.shadows)
                            checkboxRow(title: "Whites", isOn: $options.whites)
                            checkboxRow(title: "Blacks", isOn: $options.blacks)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Column 2: Presence, Treatment/Profile, Geometry
                VStack(alignment: .leading, spacing: 14) {
                    // Presence Section
                    categoryBox(title: "PRESENCE", headerTrailing: {
                        toggleAllButton(isOn: options.allPresenceEnabled) {
                            let target = !options.allPresenceEnabled
                            options.setAllPresence(target)
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            checkboxRow(title: "Texture", isOn: $options.texture)
                            checkboxRow(title: "Clarity", isOn: $options.clarity)
                            checkboxRow(title: "Dehaze", isOn: $options.dehaze)
                            checkboxRow(title: "Vibrance", isOn: $options.vibrance)
                            checkboxRow(title: "Saturation", isOn: $options.saturation)
                        }
                    }
                    
                    // Treatment & Profile
                    categoryBox(title: "TREATMENT & PROFILE") {
                        VStack(alignment: .leading, spacing: 6) {
                            checkboxRow(title: "Camera Profile", isOn: $options.cameraProfile)
                            checkboxRow(title: "Treatment (B&W / Color)", isOn: $options.treatment)
                        }
                    }
                    
                    // Geometry / Crop
                    categoryBox(title: "GEOMETRY") {
                        checkboxRow(title: "Crop", isOn: $options.crop)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(16)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // Footer Controls
            HStack(spacing: 10) {
                // Quick Select Buttons
                Button("Check All") {
                    options.checkAll(includeCrop: false)
                }
                .buttonStyle(ThemeSecondaryButtonStyle())
                .help("Check All Settings")
                
                Button("Check None") {
                    options.checkNone()
                }
                .buttonStyle(ThemeSecondaryButtonStyle())
                .help("Uncheck All Settings")
                
                if let source = sourceAsset, source.xmp.hasDevelopEdits {
                    Button("Modified Only") {
                        options.checkModified(from: source.xmp)
                    }
                    .buttonStyle(ThemeSecondaryButtonStyle())
                    .help("Check Only Modified Settings from Source Photo")
                }
                
                Spacer()
                
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ThemeSecondaryButtonStyle())
                .help("Cancel (Esc)")
                
                Button(mode.actionButtonTitle) {
                    executeAction()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ThemePrimaryButtonStyle())
                .disabled(!options.hasAnySelected)
                .help("\(mode.actionButtonTitle) Settings (Return)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(LightroomTheme.headerBackground)
        }
        .frame(width: 520)
        .background(LightroomTheme.panelBackground)
    }
    
    private func executeAction() {
        appState.lastSyncOptions = options
        if mode == .synchronize {
            appState.syncDevelopSettings(options: options)
        } else {
            appState.copyDevelopSettings(options: options)
        }
        onDismiss()
    }
    
    // MARK: - Subviews
    
    private func categoryBox<Content: View, Trailing: View>(
        title: String,
        headerTrailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(LightroomTheme.textSecondary)
                Spacer()
                headerTrailing()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LightroomTheme.cardBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(LightroomTheme.cardBorder, lineWidth: 1)
            )
        }
    }
    
    private func toggleAllButton(isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(isOn ? "Deselect All" : "Select All")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(LightroomTheme.accentYellow)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Deselect All in This Group" : "Select All in This Group")
    }
    
    private func checkboxRow(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isOn.wrappedValue ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(LightroomTheme.textPrimary)
                
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle \(title)")
    }
}

// MARK: - Custom Button Styles

private struct ThemePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isEnabled ? .black : LightroomTheme.textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isEnabled ? (configuration.isPressed ? LightroomTheme.accentYellow.opacity(0.8) : LightroomTheme.accentYellow) : LightroomTheme.cardBackground)
            .cornerRadius(4)
    }
}

private struct ThemeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .regular))
            .foregroundColor(LightroomTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? LightroomTheme.cardSelectedBackground : LightroomTheme.cardBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(LightroomTheme.cardBorder, lineWidth: 1)
            )
    }
}
