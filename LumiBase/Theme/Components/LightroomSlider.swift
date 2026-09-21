import SwiftUI

/// Custom track background styles matching Lightroom Classic's Develop panel
public enum LightroomSliderTrackStyle {
    case standard
    case temperature
    case tint
    case saturation
}

/// Professional Lightroom-style slider with color gradient tracks, center ticks, double-click to reset, and direct text input
public struct LightroomSlider: View {
    public let title: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double
    public let trackStyle: LightroomSliderTrackStyle
    public let valueFormatter: (Double) -> String
    public var onEditingChanged: ((Bool) -> Void)? = nil
    
    @FocusState private var isFieldFocused: Bool
    @State private var isEditingText: Bool = false
    @State private var textInput: String = ""
    @State private var isHoveringValue: Bool = false
    @State private var isHovering: Bool = false
    @State private var localDragValue: Double? = nil
    
    private var effectiveValue: Double {
        localDragValue ?? value
    }
    
    public init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1.0,
        defaultValue: Double = 0.0,
        trackStyle: LightroomSliderTrackStyle = .standard,
        valueFormatter: @escaping (Double) -> String = { String(format: "%+.0f", $0) },
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.trackStyle = trackStyle
        self.valueFormatter = valueFormatter
        self.onEditingChanged = onEditingChanged
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            // 1. Title Label (Double click to reset)
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isNonDefault ? LightroomTheme.textPrimary : LightroomTheme.textSecondary)
                .frame(width: 72, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    resetToDefault()
                }
                .help("Double-click to reset")
            
            // 2. Custom Slider Track & Thumb
            GeometryReader { geo in
                let width = geo.size.width
                let clampedVal = min(max(effectiveValue, range.lowerBound), range.upperBound)
                let fraction = (clampedVal - range.lowerBound) / (range.upperBound - range.lowerBound)
                let thumbX = CGFloat(fraction) * width
                
                ZStack(alignment: .leading) {
                    // Track Background
                    trackBackground
                        .frame(height: 4)
                        .cornerRadius(2)
                        .frame(maxWidth: .infinity)
                    
                    // Center tick for bipolar sliders
                    if range.lowerBound < 0 && range.upperBound > 0 {
                        let centerFraction = (0.0 - range.lowerBound) / (range.upperBound - range.lowerBound)
                        Rectangle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 1.5, height: 8)
                            .position(x: CGFloat(centerFraction) * width, y: geo.size.height / 2)
                    }
                    
                    // Draggable Thumb
                    Circle()
                        .fill(Color(white: 0.92))
                        .frame(width: 11, height: 11)
                        .shadow(color: Color.black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                        .overlay(
                            Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5)
                        )
                        .position(x: max(5.5, min(width - 5.5, thumbX)), y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            onEditingChanged?(true)
                            let newFraction = max(0.0, min(1.0, gesture.location.x / width))
                            let rawVal = range.lowerBound + Double(newFraction) * (range.upperBound - range.lowerBound)
                            let stepped = min(max((rawVal / step).rounded() * step, range.lowerBound), range.upperBound)
                            localDragValue = stepped
                            if value != stepped {
                                value = stepped
                            }
                        }
                        .onEnded { _ in
                            localDragValue = nil
                            onEditingChanged?(false)
                        }
                )
                .onTapGesture(count: 2) {
                    resetToDefault()
                }
            }
            .frame(height: 18)
            
            // 3. Numeric Value Display / Editable Field
            ZStack(alignment: .trailing) {
                if isEditingText {
                    TextField("", text: $textInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(LightroomTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(LightroomTheme.accentYellow.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: 48, alignment: .trailing)
                        .focused($isFieldFocused)
                        .onAppear {
                            isFieldFocused = true
                        }
                        .onSubmit {
                            commitTextInput()
                        }
                        .onExitCommand {
                            cancelTextInput()
                        }
                        .onChange(of: isFieldFocused) { _, focused in
                            if !focused && isEditingText {
                                commitTextInput()
                            }
                        }
                } else {
                    Text(valueFormatter(effectiveValue))
                        .font(.system(size: 10, weight: isNonDefault ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(isNonDefault ? LightroomTheme.textPrimary : LightroomTheme.textMuted)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isHoveringValue ? Color.white.opacity(0.1) : Color.clear)
                        )
                        .frame(width: 48, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            isHoveringValue = hovering
                        }
                        .onTapGesture {
                            startEditing()
                        }
                        .help("Click to edit value (Press Return to apply)")
                }
            }
            .frame(width: 48, height: 18, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .onHover { hover in
            isHovering = hover
        }
    }
    
    private var isNonDefault: Bool {
        abs(value - defaultValue) > 0.001
    }
    
    private func resetToDefault() {
        withAnimation(.easeOut(duration: 0.15)) {
            value = defaultValue
        }
        onEditingChanged?(false)
    }
    
    private func startEditing() {
        if range.upperBound <= 5.0 || step < 1.0 {
            textInput = String(format: "%.2f", effectiveValue)
        } else {
            textInput = String(format: "%.0f", effectiveValue)
        }
        isEditingText = true
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }
    
    private func cancelTextInput() {
        isEditingText = false
        isFieldFocused = false
    }
    
    private func commitTextInput() {
        isEditingText = false
        isFieldFocused = false
        let cleaned = textInput
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "K", with: "")
            .replacingOccurrences(of: "k", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(cleaned) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            let stepped: Double
            if step < 1.0 {
                stepped = (clamped / step).rounded() * step
            } else {
                stepped = clamped.rounded()
            }
            let finalValue = (stepped * 1000.0).rounded() / 1000.0
            value = finalValue
            onEditingChanged?(false)
        }
    }
    
    @ViewBuilder
    private var trackBackground: some View {
        switch trackStyle {
        case .standard:
            Color(white: 0.22)
        case .temperature:
            LinearGradient(
                colors: [
                    Color(red: 0.35, green: 0.55, blue: 1.0),
                    Color(red: 0.6, green: 0.65, blue: 0.75),
                    Color(red: 1.0, green: 0.85, blue: 0.3)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .tint:
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.85, blue: 0.45),
                    Color(red: 0.65, green: 0.65, blue: 0.7),
                    Color(red: 0.95, green: 0.25, blue: 0.85)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .saturation:
            LinearGradient(
                colors: [
                    Color(white: 0.4),
                    Color(red: 0.3, green: 0.7, blue: 0.9),
                    Color(red: 0.9, green: 0.4, blue: 0.3),
                    Color(red: 0.95, green: 0.8, blue: 0.2)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
