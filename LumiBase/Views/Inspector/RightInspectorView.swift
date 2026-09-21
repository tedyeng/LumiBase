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
            // Panel Header
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(LightroomTheme.accentYellow)
                Text("DEVELOP & METADATA")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(LightroomTheme.textSecondary)
                Spacer()
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
                        // 2. Develop (Basic) Panel Section
                        collapsibleSection(title: "BASIC (DEVELOP)", isExpanded: $isDevelopExpanded, badge: asset.xmp.hasDevelopEdits ? "Active" : nil) {
                            DevelopBasicPanelView(asset: asset, appState: appState)
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
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        .background(LightroomTheme.panelBackground)
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
