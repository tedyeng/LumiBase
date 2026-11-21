import SwiftUI

/// Mode for HSL Color Mixer
public enum HSLMixerMode: String, CaseIterable, Identifiable, Sendable {
    case hue = "Hue"
    case saturation = "Saturation"
    case luminance = "Luminance"
    case all = "All"
    
    public var id: String { rawValue }
}

/// Focus identifier for HSL Color Mixer sliders (supports Tab / Shift+Tab navigation)
public struct HSLSliderField: Hashable, Sendable {
    public let mode: HSLMixerMode
    public let band: HSLColorBand

    public init(mode: HSLMixerMode, band: HSLColorBand) {
        self.mode = mode
        self.band = band
    }
}

/// Complete Lightroom Classic HSL / Color Mixer Panel View
public struct ColorMixerPanelView: View {
    public let asset: PhotoAsset
    @ObservedObject var appState: AppState
    
    @State private var mixerMode: HSLMixerMode = .hue
    @FocusState private var focusedSlider: AnyHashable?
    
    public init(asset: PhotoAsset, appState: AppState) {
        self.asset = asset
        self.appState = appState
    }

    public static func orderedFields(for mixerMode: HSLMixerMode) -> [HSLSliderField] {
        let modes: [HSLMixerMode] = (mixerMode == .all) ? [.hue, .saturation, .luminance] : [mixerMode]
        return modes.flatMap { mode in
            HSLColorBand.allCases.map { HSLSliderField(mode: mode, band: $0) }
        }
    }

    private func nextSlider(after current: HSLSliderField) -> HSLSliderField? {
        let all = Self.orderedFields(for: mixerMode)
        guard let idx = all.firstIndex(of: current) else { return all.first }
        return all[(idx + 1) % all.count]
    }

    private func previousSlider(before current: HSLSliderField) -> HSLSliderField? {
        let all = Self.orderedFields(for: mixerMode)
        guard let idx = all.firstIndex(of: current) else { return all.last }
        return all[(idx - 1 + all.count) % all.count]
    }
    
    private var currentXMP: XMPMetadata {
        if appState.liveDevelopAssetID == asset.id, let live = appState.liveDevelopXMP {
            return live
        }
        return asset.xmp
    }
    
    private func colorForBand(_ band: HSLColorBand) -> Color {
        switch band {
        case .red: return Color.red
        case .orange: return Color.orange
        case .yellow: return Color.yellow
        case .green: return Color.green
        case .aqua: return Color(red: 0.0, green: 0.85, blue: 0.85)
        case .blue: return Color.blue
        case .purple: return Color.purple
        case .magenta: return Color(red: 0.9, green: 0.1, blue: 0.6)
        }
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            
            // Mode Header (Hue / Saturation / Luminance / All)
            HStack {
                Picker("", selection: $mixerMode) {
                    ForEach(HSLMixerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                
                Spacer()
                
                if !currentXMP.hsl.isZero {
                    Button {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                            $0.hsl = .zero
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .uiFont(9)
                            Text("Reset")
                                .uiFont(10, weight: .medium)
                        }
                        .foregroundColor(LightroomTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(LightroomTheme.cardBackground)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(LightroomTheme.cardBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Reset Color Mixer adjustments")
                }
            }
            .padding(.horizontal, 10)
            
            // Sliders Content
            VStack(spacing: 4) {
                if mixerMode == .all {
                    VStack(alignment: .leading, spacing: 12) {
                        // Hue Section
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HUE")
                                .uiFont(9, weight: .bold)
                                .foregroundColor(LightroomTheme.textMuted)
                                .padding(.horizontal, 2)
                                .padding(.top, 2)
                            ForEach(HSLColorBand.allCases) { band in
                                renderBandRow(band, mode: .hue)
                            }
                        }
                        
                        Divider().background(LightroomTheme.dividerColor)
                        
                        // Saturation Section
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SATURATION")
                                .uiFont(9, weight: .bold)
                                .foregroundColor(LightroomTheme.textMuted)
                                .padding(.horizontal, 2)
                                .padding(.top, 2)
                            ForEach(HSLColorBand.allCases) { band in
                                renderBandRow(band, mode: .saturation)
                            }
                        }
                        
                        Divider().background(LightroomTheme.dividerColor)
                        
                        // Luminance Section
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LUMINANCE")
                                .uiFont(9, weight: .bold)
                                .foregroundColor(LightroomTheme.textMuted)
                                .padding(.horizontal, 2)
                                .padding(.top, 2)
                            ForEach(HSLColorBand.allCases) { band in
                                renderBandRow(band, mode: .luminance)
                            }
                        }
                    }
                } else {
                    // Single Mode (Hue, Saturation, or Luminance across all 8 bands)
                    ForEach(HSLColorBand.allCases) { band in
                        renderBandRow(band, mode: mixerMode)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
    }
    
    // MARK: - Row Renderers
    
    @ViewBuilder
    private func renderBandRow(_ band: HSLColorBand, mode: HSLMixerMode) -> some View {
        let bandColor = colorForBand(band)
        let sliderField = HSLSliderField(mode: mode, band: band)
        
        LightroomSlider(
            title: band.rawValue,
            value: Binding(
                get: {
                    switch mode {
                    case .hue: return Double(currentXMP.hsl[band].hue)
                    case .saturation: return Double(currentXMP.hsl[band].saturation)
                    case .luminance: return Double(currentXMP.hsl[band].luminance)
                    case .all: return 0.0
                    }
                },
                set: { newVal in
                    appState.updateDevelopSettings(for: asset.id, isDragging: true) { xmp in
                        switch mode {
                        case .hue: xmp.hsl[band].hue = Int(newVal)
                        case .saturation: xmp.hsl[band].saturation = Int(newVal)
                        case .luminance: xmp.hsl[band].luminance = Int(newVal)
                        case .all: break
                        }
                    }
                }
            ),
            range: -100...100,
            step: 1,
            defaultValue: 0,
            trackStyle: .standard,
            valueFormatter: { String(format: "%+d", Int($0)) },
            leadingColor: bandColor,
            customField: sliderField,
            focusedCustomField: $focusedSlider,
            onNextField: {
                focusedSlider = nextSlider(after: sliderField)
            },
            onPreviousField: {
                focusedSlider = previousSlider(before: sliderField)
            },
            onEditingChanged: { isEditing in
                if !isEditing {
                    appState.updateDevelopSettings(for: asset.id, isDragging: false) { _ in }
                }
            },
            onReset: {
                appState.updateDevelopSettings(for: asset.id, isDragging: false) { xmp in
                    switch mode {
                    case .hue: xmp.hsl[band].hue = 0
                    case .saturation: xmp.hsl[band].saturation = 0
                    case .luminance: xmp.hsl[band].luminance = 0
                    case .all: break
                    }
                }
            }
        )
    }
}
