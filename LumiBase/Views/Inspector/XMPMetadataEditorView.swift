import SwiftUI

/// Inspector panel editor for XMP sidecar fields (Rating, Color Label, Flag, Keywords, Title, Caption)
public struct XMPMetadataEditorView: View {
    public let asset: PhotoAsset
    @ObservedObject var appState: AppState
    
    @State private var newKeyword: String = ""
    @State private var titleText: String = ""
    @State private var captionText: String = ""
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // 0. XMP Sidecar Status Banner
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(asset.xmp.isLoadedFromSidecar ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(asset.xmp.isLoadedFromSidecar ? "XMP Sidecar Loaded" : "No XMP Sidecar")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(asset.xmp.isLoadedFromSidecar ? .green : LightroomTheme.textMuted)
                    }
                    Spacer()
                    if asset.xmp.hasDevelopEdits {
                        Text("Develop Edits Active")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(LightroomTheme.accentYellow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LightroomTheme.accentYellow.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                
                if let sidecarName = asset.xmp.sidecarFilename {
                    Text("File: \(sidecarName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(LightroomTheme.textSecondary)
                } else if asset.xmp.isLoadedFromSidecar {
                    Text("File: \(asset.fileURL.deletingPathExtension().lastPathComponent).xmp")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(LightroomTheme.textSecondary)
                }
            }
            .padding(8)
            .background(LightroomTheme.cardBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(asset.xmp.isLoadedFromSidecar ? Color.green.opacity(0.4) : LightroomTheme.cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 1. Rating & Flag Row
            HStack {
                Text("Rating & Flag")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LightroomTheme.textSecondary)
                Spacer()
                
                // Pick / Reject Flags
                HStack(spacing: 8) {
                    flagButton(flag: .pick, title: "P", color: .white, active: asset.xmp.flag == .pick)
                    flagButton(flag: .reject, title: "X", color: .red, active: asset.xmp.flag == .reject)
                }
            }
            .padding(.horizontal, 10)
            
            HStack {
                RatingStarsView(
                    rating: asset.xmp.rating,
                    starSize: 16,
                    isInteractive: true,
                    onRatingChanged: { newRating in
                        appState.setRating(newRating)
                    }
                )
                
                Spacer()
                
                if asset.xmp.rating > 0 {
                    Button("Clear") {
                        appState.setRating(0)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(LightroomTheme.textMuted)
                    .buttonStyle(.plain)
                    .help("Clear Rating (0)")
                }
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 2. Keywords / Tags
            VStack(alignment: .leading, spacing: 6) {
                Text("Keywords")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                // Add keyword input
                HStack(spacing: 6) {
                    TextField("Add keyword...", text: $newKeyword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .onSubmit {
                            addKeyword()
                        }
                    
                    Button("+") {
                        addKeyword()
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(LightroomTheme.accentYellow)
                    .buttonStyle(.plain)
                    .help("Add Keyword (Return)")
                }
                
                // Keyword Tag Cloud
                if !asset.xmp.keywords.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(asset.xmp.keywords, id: \.self) { kw in
                            HStack(spacing: 4) {
                                Text(kw)
                                    .font(.system(size: 10))
                                    .foregroundColor(LightroomTheme.textPrimary)
                                Button {
                                    removeKeyword(kw)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                        .foregroundColor(LightroomTheme.textMuted)
                                }
                                .buttonStyle(.plain)
                                .help("Remove Keyword: \(kw)")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(LightroomTheme.cardSelectedBackground)
                            .cornerRadius(3)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 4. Title & Caption
            VStack(alignment: .leading, spacing: 6) {
                Text("Title & Caption")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                TextField("Photo Title", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(5)
                    .background(LightroomTheme.cardBackground)
                    .cornerRadius(3)
                    .onChange(of: titleText) { _, newValue in
                        appState.updateMetadata(
                            keywords: asset.xmp.keywords,
                            title: newValue.isEmpty ? nil : newValue,
                            caption: captionText.isEmpty ? nil : captionText
                        )
                    }
                
                TextField("Caption / Description", text: $captionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(5)
                    .background(LightroomTheme.cardBackground)
                    .cornerRadius(3)
                    .onChange(of: captionText) { _, newValue in
                        appState.updateMetadata(
                            keywords: asset.xmp.keywords,
                            title: titleText.isEmpty ? nil : titleText,
                            caption: newValue.isEmpty ? nil : newValue
                        )
                    }
            }
            .padding(.horizontal, 10)
            
            // 5. Camera RAW Adjustments (From XMP)
            if asset.xmp.hasDevelopEdits {
                Divider().background(LightroomTheme.dividerColor)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(LightroomTheme.accentYellow)
                            .font(.system(size: 10))
                        Text("Camera RAW Adjustments (XMP)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(LightroomTheme.textSecondary)
                        Spacer()
                    }
                    
                    VStack(spacing: 4) {
                        if let ev = asset.xmp.exposure2012 {
                            developRow(title: "Exposure", value: String(format: "%+.2f EV", ev), icon: "sun.max.fill")
                        }
                        if let temp = asset.xmp.temperature {
                            developRow(title: "Temperature", value: "\(temp) K", icon: "thermometer.sun.fill")
                        }
                        if let tint = asset.xmp.tint {
                            developRow(title: "Tint", value: String(format: "%+d", tint), icon: "eyedropper.halffull")
                        }
                        if let contrast = asset.xmp.contrast2012 {
                            developRow(title: "Contrast", value: String(format: "%+d", contrast), icon: "circle.righthalf.filled")
                        }
                        if let hl = asset.xmp.highlights2012 {
                            developRow(title: "Highlights", value: String(format: "%+d", hl), icon: "light.max")
                        }
                        if let sh = asset.xmp.shadows2012 {
                            developRow(title: "Shadows", value: String(format: "%+d", sh), icon: "shadow")
                        }
                        if asset.xmp.hasCrop {
                            developRow(title: "Crop", value: "Applied", icon: "crop")
                        }
                        let profileText = asset.xmp.cameraProfile ?? (DCPProfileManager.shared.locateDCPProfile(cameraModel: asset.cameraMetadata.model) != nil ? "Adobe Standard (DCP Linked)" : "Adobe Standard")
                        developRow(title: "Profile", value: profileText, icon: "camera.aperture")
                    }
                    .padding(6)
                    .background(LightroomTheme.cardBackground)
                    .cornerRadius(4)
                }
                .padding(.horizontal, 10)
            }
        }
        .onAppear {
            titleText = asset.xmp.title ?? ""
            captionText = asset.xmp.caption ?? ""
        }
        .onChange(of: asset.id) { _, _ in
            titleText = asset.xmp.title ?? ""
            captionText = asset.xmp.caption ?? ""
        }
    }
    
    private func developRow(title: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(LightroomTheme.textMuted)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(LightroomTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(LightroomTheme.textPrimary)
        }
        .padding(.vertical, 1)
    }
    
    private func flagButton(flag: FlagStatus, title: String, color: Color, active: Bool) -> some View {
        Button {
            appState.setFlag(active ? .unflagged : flag)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(active ? color : LightroomTheme.textMuted.opacity(0.4))
                .frame(width: 22, height: 20)
                .background(active ? LightroomTheme.cardSelectedBackground : Color.clear)
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(active ? color.opacity(0.6) : LightroomTheme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(flag == .pick ? "Flag as Pick (P)" : "Flag as Reject (X)")
    }
    
    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = asset.xmp.keywords
        if !current.contains(trimmed) {
            current.append(trimmed)
            appState.updateMetadata(keywords: current, title: titleText, caption: captionText)
        }
        newKeyword = ""
    }
    
    private func removeKeyword(_ kw: String) {
        var current = asset.xmp.keywords
        current.removeAll { $0 == kw }
        appState.updateMetadata(keywords: current, title: titleText, caption: captionText)
    }
}

/// Simple flow layout helper for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 200
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
        height = currentY + maxHeightInRow
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}
