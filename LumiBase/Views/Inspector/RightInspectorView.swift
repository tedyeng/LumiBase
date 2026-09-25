import SwiftUI

/// Right panel: Histogram, EXIF Info, and XMP Metadata Inspector
public struct RightInspectorView: View {
    @ObservedObject var appState: AppState
    
    @State private var isHistogramExpanded: Bool = true
    @State private var isDevelopExpanded: Bool = true
    @State private var isMetadataExpanded: Bool = true
    @State private var isEXIFExpanded: Bool = true
    
    public var body: some View {
        VStack(spacing: 0) {
            // Panel Header with Tool Switcher
            HStack(spacing: 6) {
                Text("DEVELOP & METADATA")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                Spacer()
                
                // Tool Switcher: Adjust/Edit vs Crop & Straighten
                HStack(spacing: 2) {
                    Button {
                        appState.activeDevelopTool = .edit
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                            .foregroundColor(appState.activeDevelopTool == .edit ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(appState.activeDevelopTool == .edit ? LightroomTheme.accentYellow.opacity(0.18) : Color.clear)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("Edit Adjustments (E)")
                    
                    Button {
                        appState.toggleCropMode()
                    } label: {
                        Image(systemName: "crop")
                            .font(.system(size: 11))
                            .foregroundColor(appState.activeDevelopTool == .crop ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(appState.activeDevelopTool == .crop ? LightroomTheme.accentYellow.opacity(0.18) : Color.clear)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("Crop & Straighten (R)")
                }
                .padding(2)
                .background(LightroomTheme.cardBackground)
                .cornerRadius(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LightroomTheme.headerBackground)
            
            Divider().background(LightroomTheme.dividerColor)
            
            ScrollView {
                VStack(spacing: 12) {
                    
                    // 1. Histogram Section
                    collapsibleSection(title: "HISTOGRAM", isExpanded: $isHistogramExpanded) {
                        HistogramView(asset: appState.primarySelectedAsset)
                    }
                    
                    Divider().background(LightroomTheme.dividerColor)
                    
                    if let asset = appState.primarySelectedAsset {
                        if appState.activeDevelopTool == .crop {
                            // 2a. Crop & Rotate Tool Panel Section
                            collapsibleSection(title: "CROP & STRAIGHTEN", isExpanded: $isDevelopExpanded, badge: asset.xmp.hasCrop ? "Active" : nil) {
                                CropControlPanelView(asset: asset, appState: appState)
                            }
                        } else {
                            // 2b. Develop (Basic) Panel Section
                            collapsibleSection(title: "BASIC (DEVELOP)", isExpanded: $isDevelopExpanded, badge: asset.xmp.hasDevelopEdits ? "Active" : nil) {
                                DevelopBasicPanelView(asset: asset, appState: appState)
                            }
                        }
                        
                        Divider().background(LightroomTheme.dividerColor)
                        
                        // 3. XMP Metadata & Rating Editor Section
                        collapsibleSection(title: "METADATA (XMP)", isExpanded: $isMetadataExpanded) {
                            XMPMetadataEditorView(asset: asset, appState: appState)
                        }
                        
                        Divider().background(LightroomTheme.dividerColor)
                        
                        // 4. EXIF Info Section
                        collapsibleSection(title: "EXIF INFO", isExpanded: $isEXIFExpanded) {
                            EXIFInfoView(asset: asset)
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(LightroomTheme.textMuted)
                            Text("No photo selected")
                                .font(.system(size: 11))
                                .foregroundColor(LightroomTheme.textMuted)
                        }
                        .padding(.top, 40)
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Bottom Develop Actions Bar (Copy / Paste / Sync / Auto Sync)
            Divider().background(LightroomTheme.dividerColor)
            developFooterBar
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        .background(LightroomTheme.panelBackground)
    }
    
    private var developFooterBar: some View {
        HStack(spacing: 8) {
            // Left: Copy & Paste
            HStack(spacing: 6) {
                Button {
                    appState.showCopySettingsDialog = true
                } label: {
                    Text("Copy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(appState.primarySelectedAsset != nil ? LightroomTheme.textPrimary : LightroomTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(appState.primarySelectedAsset == nil)
                .help("Copy Develop Settings (Cmd+Shift+C)")
                
                Button {
                    appState.pasteDevelopSettings()
                } label: {
                    Text("Paste")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(appState.copiedDevelopSettings != nil ? LightroomTheme.textPrimary : LightroomTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(appState.copiedDevelopSettings == nil)
                .help("Paste Develop Settings (Cmd+Shift+V)")
            }
            
            Spacer()
            
            // Right: Sync / Auto Sync (Multi-selection) or Reset (Single selection)
            if appState.selectedAssetIDs.count > 1 {
                HStack(spacing: 4) {
                    // Auto Sync Switch Toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.toggleAutoSync()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(appState.isAutoSyncEnabled ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                                .frame(width: 6, height: 6)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .background(appState.isAutoSyncEnabled ? LightroomTheme.accentYellow.opacity(0.15) : LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(appState.isAutoSyncEnabled ? LightroomTheme.accentYellow.opacity(0.6) : LightroomTheme.cardBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Auto Sync (Cmd+Option+Shift+S)")
                    
                    if appState.isAutoSyncEnabled {
                        // Auto Sync Active Button
                        Button {
                            appState.showSyncDialog = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                Text("Auto Sync")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(LightroomTheme.accentYellow)
                            .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                        .help("Auto Sync is active: adjustments apply instantly to all selected photos. Click to configure Sync Settings (Cmd+Shift+S)")
                    } else {
                        // Standard Sync Button
                        Button {
                            appState.showSyncDialog = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9))
                                Text("Sync")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(LightroomTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(LightroomTheme.cardBackground)
                            .cornerRadius(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Synchronize Develop Settings to all selected photos (Cmd+Shift+S)")
                    }
                }
            } else {
                // Reset Button when single photo is selected
                if let asset = appState.primarySelectedAsset, asset.xmp.hasDevelopEdits {
                    Button {
                        appState.resetDevelopSettings()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                            Text("Reset")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(LightroomTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Reset all Develop adjustments to default")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LightroomTheme.headerBackground)
    }
    
    private func collapsibleSection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        badge: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(LightroomTheme.textMuted)
                    
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(LightroomTheme.textSecondary)
                    
                    if let badge = badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(LightroomTheme.accentYellow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LightroomTheme.accentYellow.opacity(0.15))
                            .cornerRadius(3)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded.wrappedValue {
                content()
            }
        }
    }
}
