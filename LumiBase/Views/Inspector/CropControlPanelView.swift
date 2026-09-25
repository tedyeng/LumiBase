import SwiftUI

/// Lightroom Classic-style Crop & Rotate Tool Control Panel for Right Inspector
public struct CropControlPanelView: View {
    public let asset: PhotoAsset
    @ObservedObject var appState: AppState
    
    public init(asset: PhotoAsset, appState: AppState) {
        self.asset = asset
        self.appState = appState
    }
    
    private var currentXMP: XMPMetadata {
        if appState.liveDevelopAssetID == asset.id, let live = appState.liveDevelopXMP {
            return live
        }
        return asset.xmp
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // 1. Aspect Ratio Selector & Lock Row
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Aspect Ratio:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(LightroomTheme.textSecondary)
                    
                    Spacer()
                    
                    // Lock / Unlock Aspect Ratio Button
                    Button {
                        appState.isCropAspectLocked.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: appState.isCropAspectLocked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 10))
                                .foregroundColor(appState.isCropAspectLocked ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                            Text(appState.isCropAspectLocked ? "Locked" : "Unlocked")
                                .font(.system(size: 10))
                                .foregroundColor(appState.isCropAspectLocked ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("Lock or unlock crop aspect ratio")
                }
                
                HStack(spacing: 8) {
                    // Preset Menu
                    Menu {
                        ForEach(CropAspectRatioPreset.allCases) { preset in
                            Button(preset.displayName) {
                                appState.setCropPreset(preset)
                            }
                        }
                    } label: {
                        HStack {
                            Text(appState.cropAspectRatioPreset.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(LightroomTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(LightroomTheme.textMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    
                    // Flip Orientation Button (X shortcut)
                    Button {
                        appState.flipCropOrientation()
                    } label: {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 11))
                            .foregroundColor(LightroomTheme.textPrimary)
                            .padding(6)
                            .background(LightroomTheme.cardBackground)
                            .cornerRadius(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Flip crop orientation between landscape and portrait (X)")
                }
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 2. Straighten / Angle Slider
            VStack(alignment: .leading, spacing: 6) {
                LightroomSlider(
                    title: "Angle",
                    value: Binding(
                        get: { currentXMP.cropAngle ?? 0.0 },
                        set: { newVal in
                            appState.updateCropAngle(newVal, for: asset.id, isDragging: true)
                        }
                    ),
                    range: -45.0...45.0,
                    step: 0.1,
                    defaultValue: 0.0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+.1f°", $0) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateCropAngle(currentXMP.cropAngle ?? 0.0, for: asset.id, isDragging: false)
                        }
                    }
                )
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 3. Tool Overlay Guide Style Row (Grid vs Thirds, Shortcut: O)
            HStack {
                Text("Tool Overlay:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                Spacer()
                
                Button {
                    appState.cycleCropOverlayStyle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.cropOverlayStyle == .grid ? "grid" : "square.split.3x3")
                            .font(.system(size: 10))
                        Text(appState.cropOverlayStyle.displayName)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(LightroomTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(LightroomTheme.cardBackground)
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Cycle tool overlay guide style (O)")
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 4. Quick Action Buttons: Reset & Done
            HStack(spacing: 8) {
                if currentXMP.hasCrop {
                    Button {
                        appState.resetCrop(for: asset.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                            Text("Reset Crop")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(LightroomTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("Reset crop to full frame")
                }
                
                Spacer()
                
                Button {
                    appState.activeDevelopTool = .edit
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Done")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(LightroomTheme.accentYellow)
                    .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("Commit and close crop tool (Enter / R)")
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .background(LightroomTheme.cardBackground.opacity(0.3))
        .cornerRadius(4)
    }
}
