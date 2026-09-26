import SwiftUI

/// Native tracking resolves the second click before a zero-distance drag can
/// consume it. No global monitor; AppKit retains ordinary mouse drag ownership.
struct SliderTrackInput: NSViewRepresentable {
    let changed: (Double) -> Void
    let ended: () -> Void
    let reset: () -> Void
    func makeNSView(context: Context) -> SliderTrackView { SliderTrackView() }
    func updateNSView(_ view: SliderTrackView, context: Context) {
        view.changed = changed; view.ended = ended; view.reset = reset
    }
}
final class SliderTrackView: NSView {
    var changed: ((Double) -> Void)?
    var ended: (() -> Void)?
    var reset: (() -> Void)?
    private var dragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { dragging = false; reset?(); return }
        dragging = true
        apply(event)
    }
    override func mouseDragged(with event: NSEvent) { if dragging { apply(event) } }
    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; ended?() }
    }
    private func apply(_ event: NSEvent) {
        guard bounds.width > 0 else { return }
        changed?(Double(min(1, max(0, convert(event.locationInWindow, from: nil).x / bounds.width))))
    }
}

/// Identifiers for all editable Basic panel adjustment sliders
public enum BasicSliderField: String, CaseIterable, Hashable {
    case temp
    case tint
    case exposure
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case texture
    case clarity
    case dehaze
    case vibrance
    case saturation

    /// nil restores each photo's as-shot WB, not an arbitrary Kelvin/tint value.
    func reset(in xmp: inout XMPMetadata) {
        switch self {
        case .temp: xmp.temperature = nil
        case .tint: xmp.tint = nil
        case .exposure: xmp.exposure2012 = nil
        case .contrast: xmp.contrast2012 = nil
        case .highlights: xmp.highlights2012 = nil
        case .shadows: xmp.shadows2012 = nil
        case .whites: xmp.whites2012 = nil
        case .blacks: xmp.blacks2012 = nil
        case .texture: xmp.texture = nil
        case .clarity: xmp.clarity2012 = nil
        case .dehaze: xmp.dehaze = nil
        case .vibrance: xmp.vibrance = nil
        case .saturation: xmp.saturation = nil
        }
    }
    func isDefault(in xmp: XMPMetadata) -> Bool {
        var reset = xmp
        self.reset(in: &reset)
        return reset == xmp
    }
}

/// Custom track background styles matching Lightroom Classic's Develop panel
public enum LightroomSliderTrackStyle {
    case standard
    case temperature
    case tint
    case saturation
}

/// Professional Lightroom-style slider with color gradient tracks, center ticks, double-click to reset, and direct text input with Tab navigation
public struct LightroomSlider: View {
    public let title: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double
    public let trackStyle: LightroomSliderTrackStyle
    public let valueFormatter: (Double) -> String
    public var onEditingChanged: ((Bool) -> Void)? = nil
    public var onReset: (() -> Void)? = nil
    
    public var field: BasicSliderField? = nil
    public var focusedField: FocusState<BasicSliderField?>.Binding? = nil
    public var onNextField: (() -> Void)? = nil
    public var onPreviousField: (() -> Void)? = nil
    
    @FocusState private var isLocalFocused: Bool
    @State private var textInput: String = ""
    @State private var isHoveringValue: Bool = false
    @State private var isHovering: Bool = false
    @State private var localDragValue: Double? = nil
    
    private var isEditing: Bool {
        if let focusedField = focusedField, let field = field {
            return focusedField.wrappedValue == field
        }
        return isLocalFocused
    }
    
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
        field: BasicSliderField? = nil,
        focusedField: FocusState<BasicSliderField?>.Binding? = nil,
        onNextField: (() -> Void)? = nil,
        onPreviousField: (() -> Void)? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil,
        onReset: (() -> Void)? = nil
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.trackStyle = trackStyle
        self.valueFormatter = valueFormatter
        self.field = field
        self.focusedField = focusedField
        self.onNextField = onNextField
        self.onPreviousField = onPreviousField
        self.onEditingChanged = onEditingChanged
        self.onReset = onReset
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
                .overlay(SliderTrackInput(changed: { fraction in
                            onEditingChanged?(true)
                            let rawVal = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                            let stepped = min(max((rawVal / step).rounded() * step, range.lowerBound), range.upperBound)
                            localDragValue = stepped
                            if value != stepped {
                                value = stepped
                            }
                    }, ended: {
                        localDragValue = nil
                        onEditingChanged?(false)
                    }, reset: { resetToDefault() }))
            }
            .frame(height: 18)
            
            // 3. Numeric Value Display / Editable Field
            ZStack(alignment: .trailing) {
                // Background interactive text field - always in hierarchy so FocusState / FirstResponder is never dropped
                editableTextField
                    .opacity(isEditing ? 1.0 : 0.0)
                    .allowsHitTesting(isEditing)
                
                // Static formatted display label - active when not editing
                if !isEditing {
                    Text(valueFormatter(effectiveValue))
                        .font(.system(size: 10, weight: isNonDefault ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(isNonDefault ? LightroomTheme.textPrimary : LightroomTheme.textMuted)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .frame(width: 48, height: 18, alignment: .trailing)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isHoveringValue ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            isHoveringValue = hovering
                        }
                        .gesture(TapGesture(count: 2).onEnded { resetToDefault() }
                            .exclusively(before: TapGesture().onEnded { startEditing() }))
                        .help("Double-click to reset; click to edit (Tab for next, Return to apply)")
                }
            }
            .frame(width: 48, height: 18, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .onHover { hover in
            isHovering = hover
        }
        .onChange(of: focusedField?.wrappedValue) { oldField, newField in
            if let field = field {
                if newField == field {
                    DispatchQueue.main.async {
                        syncTextInput()
                    }
                } else if oldField == field {
                    DispatchQueue.main.async {
                        commitTextInput()
                    }
                }
            }
        }
        .onChange(of: isLocalFocused) { oldFocus, newFocus in
            if newFocus {
                DispatchQueue.main.async {
                    syncTextInput()
                }
            } else if oldFocus {
                DispatchQueue.main.async {
                    commitTextInput()
                }
            }
        }
    }
    
    @ViewBuilder
    private var editableTextField: some View {
        let fieldView = TextField("", text: $textInput)
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
            .frame(width: 48, height: 18, alignment: .trailing)
            .onSubmit {
                commitTextInput()
                exitFocus()
            }
            .onExitCommand {
                cancelTextInput()
                exitFocus()
            }
            .onKeyPress { press in
                if press.key == .tab {
                    commitTextInput()
                    if press.modifiers.contains(.shift) {
                        onPreviousField?()
                    } else {
                        onNextField?()
                    }
                    return .handled
                }
                return .ignored
            }
        
        if let focusedField = focusedField, let field = field {
            fieldView.focused(focusedField, equals: field)
        } else {
            fieldView.focused($isLocalFocused)
        }
    }
    
    private var isNonDefault: Bool {
        abs(value - defaultValue) > 0.001
    }
    
    private func resetToDefault() {
        localDragValue = nil
        if let onReset { onReset() }
        else { value = defaultValue; onEditingChanged?(false) }
        // Discard an active draft before resigning focus. In particular, a WB
        // reset must not be overwritten by the numeric fallback on focus loss.
        textInput = ""
        exitFocus()
    }
    
    private func syncTextInput() {
        if range.upperBound <= 5.0 || step < 1.0 {
            textInput = String(format: "%.2f", effectiveValue)
        } else {
            textInput = String(format: "%.0f", effectiveValue)
        }
    }
    
    private func startEditing() {
        syncTextInput()
        if let focusedField = focusedField, let field = field {
            focusedField.wrappedValue = field
        } else {
            isLocalFocused = true
        }
    }
    
    private func cancelTextInput() {
        // Cancel input without applying
    }
    
    private func commitTextInput() {
        let cleaned = textInput
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "K", with: "")
            .replacingOccurrences(of: "k", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(cleaned) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            let stepped: Double
            if step < 1.0 {
                stepped = (clamped * 100.0).rounded() / 100.0
            } else {
                stepped = clamped.rounded()
            }
            if abs(value - stepped) > 0.0001 {
                DispatchQueue.main.async {
                    self.value = stepped
                    self.onEditingChanged?(false)
                }
            }
        }
    }
    
    private func exitFocus() {
        if isLocalFocused {
            isLocalFocused = false
        }
        if let focusedField = focusedField, focusedField.wrappedValue == field {
            focusedField.wrappedValue = nil
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
