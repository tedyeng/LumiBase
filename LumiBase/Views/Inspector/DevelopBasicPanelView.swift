import SwiftUI

/// Complete Lightroom Classic Develop "Basic" Panel View
public struct DevelopBasicPanelView: View {
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
        VStack(alignment: .leading, spacing: 10) {
            
            // 1. Top Quick Action Bar: Auto, Treatment (Color / B&W), Reset
            HStack(spacing: 8) {
                actionButton(title: "Auto", icon: "wand.and.stars") {
                    appState.autoTone(for: asset.id)
                }
                
                let isBW = (currentXMP.convertToGrayscale == true || currentXMP.saturation == -100)
                actionButton(title: isBW ? "Color" : "B&W", icon: "circle.righthalf.filled", isActive: isBW) {
                    appState.toggleMonochrome(for: asset.id)
                }
                
                Spacer()
                
                if currentXMP.hasDevelopEdits {
                    Button {
                        appState.resetDevelopSettings(for: asset.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                            Text("Reset")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(LightroomTheme.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("Reset all basic adjustments")
                }
            }
            .padding(.horizontal, 10)
            
            // 2. Profile Selector Row
            HStack {
                Text("Profile:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                let profileName = currentXMP.cameraProfile ?? "Adobe Color"
                Menu {
                    Button("Adobe Color") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Color" }
                    }
                    Button("Adobe Standard") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Standard" }
                    }
                    Button("Adobe Portrait") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Portrait" }
                    }
                    Button("Adobe Landscape") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Landscape" }
                    }
                    Button("Adobe Vivid") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Vivid" }
                    }
                    Button("Adobe Monochrome") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Monochrome" }
                    }
                    Button("Adobe Neutral") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Adobe Neutral" }
                    }
                    Divider()
                    Button("Camera Standard") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) { $0.cameraProfile = "Camera Standard" }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(profileName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(LightroomTheme.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(LightroomTheme.textMuted)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(LightroomTheme.cardBackground)
                    .cornerRadius(3)
                }
                .menuStyle(.borderlessButton)
                
                Spacer()
                
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10))
                    .foregroundColor(LightroomTheme.textMuted)
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 3. White Balance (WB)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 10))
                        .foregroundColor(LightroomTheme.textMuted)
                    
                    Text("WB :")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(LightroomTheme.textSecondary)
                    
                    Menu {
                        Button("As Shot") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = nil
                                $0.tint = nil
                            }
                        }
                        Button("Auto") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 5200
                                $0.tint = 2
                            }
                        }
                        Button("Daylight (5500K)") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 5500
                                $0.tint = 10
                            }
                        }
                        Button("Cloudy (6500K)") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 6500
                                $0.tint = 10
                            }
                        }
                        Button("Shade (7500K)") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 7500
                                $0.tint = 10
                            }
                        }
                        Button("Tungsten (2850K)") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 2850
                                $0.tint = 0
                            }
                        }
                        Button("Fluorescent (3800K)") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 3800
                                $0.tint = 20
                            }
                        }
                        Button("Flash (5500K)") {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                                $0.temperature = 5500
                                $0.tint = 0
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(wbModeTitle)
                                .font(.system(size: 10))
                                .foregroundColor(LightroomTheme.textPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(LightroomTheme.textMuted)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    
                    Spacer()
                }
                
                // Temp Slider (2000K to 50000K Kelvin - Adobe Lightroom Standard)
                LightroomSlider(
                    title: "Temp",
                    value: Binding(
                        get: { Double(currentXMP.temperature ?? 5500) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.temperature = Int(newVal) }
                        }
                    ),
                    range: 2000...50000,
                    step: 50,
                    defaultValue: 5500,
                    trackStyle: .temperature,
                    valueFormatter: { String(format: "%d K", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Tint Slider
                LightroomSlider(
                    title: "Tint",
                    value: Binding(
                        get: { Double(currentXMP.tint ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.tint = Int(newVal) }
                        }
                    ),
                    range: -150...150,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .tint,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 4. Tone Section (Exposure, Contrast, Highlights, Shadows, Whites, Blacks)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tone")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                // Exposure
                LightroomSlider(
                    title: "Exposure",
                    value: Binding(
                        get: { currentXMP.exposure2012 ?? 0.0 },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.exposure2012 = (abs(newVal) < 0.001) ? nil : newVal }
                        }
                    ),
                    range: -5.0...5.0,
                    step: 0.05,
                    defaultValue: 0.0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+.2f", $0) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Contrast
                LightroomSlider(
                    title: "Contrast",
                    value: Binding(
                        get: { Double(currentXMP.contrast2012 ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.contrast2012 = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Highlights
                LightroomSlider(
                    title: "Highlights",
                    value: Binding(
                        get: { Double(currentXMP.highlights2012 ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.highlights2012 = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Shadows
                LightroomSlider(
                    title: "Shadows",
                    value: Binding(
                        get: { Double(currentXMP.shadows2012 ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.shadows2012 = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Whites
                LightroomSlider(
                    title: "Whites",
                    value: Binding(
                        get: { Double(currentXMP.whites2012 ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.whites2012 = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Blacks
                LightroomSlider(
                    title: "Blacks",
                    value: Binding(
                        get: { Double(currentXMP.blacks2012 ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.blacks2012 = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
            }
            .padding(.horizontal, 10)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // 5. Presence Section (Texture, Clarity, Dehaze, Vibrance, Saturation)
            VStack(alignment: .leading, spacing: 6) {
                Text("Presence")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                // Texture
                LightroomSlider(
                    title: "Texture",
                    value: Binding(
                        get: { Double(currentXMP.texture ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.texture = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Clarity
                LightroomSlider(
                    title: "Clarity",
                    value: Binding(
                        get: { Double(currentXMP.clarity2012 ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.clarity2012 = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Dehaze
                LightroomSlider(
                    title: "Dehaze",
                    value: Binding(
                        get: { Double(currentXMP.dehaze ?? 0) },
                        set: { newVal in
                            appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.dehaze = (newVal == 0) ? nil : Int(newVal) }
                        }
                    ),
                    range: -100...100,
                    step: 1,
                    defaultValue: 0,
                    trackStyle: .standard,
                    valueFormatter: { String(format: "%+d", Int($0)) },
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                        }
                    }
                )
                
                // Vibrance & Saturation (Hidden in Black & White mode, matching Lightroom Classic)
                let isBW = (currentXMP.convertToGrayscale == true || currentXMP.saturation == -100)
                if !isBW {
                    // Vibrance
                    LightroomSlider(
                        title: "Vibrance",
                        value: Binding(
                            get: { Double(currentXMP.vibrance ?? 0) },
                            set: { newVal in
                                appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.vibrance = (newVal == 0) ? nil : Int(newVal) }
                            }
                        ),
                        range: -100...100,
                        step: 1,
                        defaultValue: 0,
                        trackStyle: .saturation,
                        valueFormatter: { String(format: "%+d", Int($0)) },
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                            }
                        }
                    )
                    
                    // Saturation
                    LightroomSlider(
                        title: "Saturation",
                        value: Binding(
                            get: { Double(currentXMP.saturation ?? 0) },
                            set: { newVal in
                                appState.updateDevelopSettings(for: asset.id, isDragging: true) { $0.saturation = (newVal == 0) ? nil : Int(newVal) }
                            }
                        ),
                        range: -100...100,
                        step: 1,
                        defaultValue: 0,
                        trackStyle: .saturation,
                        valueFormatter: { String(format: "%+d", Int($0)) },
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                            }
                        }
                    )
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.righthalf.filled")
                            .font(.system(size: 9))
                            .foregroundColor(LightroomTheme.textMuted)
                        Text("Treatment is Black & White")
                            .font(.system(size: 10))
                            .foregroundColor(LightroomTheme.textMuted)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
    }
    
    private var wbModeTitle: String {
        guard let temp = currentXMP.temperature else {
            return "As Shot"
        }
        let tint = currentXMP.tint ?? 0
        if temp == 5200 && tint == 2 { return "Auto" }
        if temp == 5500 && tint == 10 { return "Daylight" }
        if temp == 6500 && tint == 10 { return "Cloudy" }
        if temp == 7500 && tint == 10 { return "Shade" }
        if temp == 2850 && tint == 0 { return "Tungsten" }
        if temp == 3800 && tint == 20 { return "Fluorescent" }
        if temp == 5500 && tint == 0 { return "Flash" }
        return "Custom"
    }
    
    private func actionButton(title: String, icon: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isActive ? LightroomTheme.accentYellow : LightroomTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isActive ? LightroomTheme.cardSelectedBackground : LightroomTheme.cardBackground)
            .cornerRadius(3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isActive ? LightroomTheme.accentYellow.opacity(0.5) : LightroomTheme.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
