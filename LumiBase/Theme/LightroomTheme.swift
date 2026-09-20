import SwiftUI

/// Lightroom Classic-inspired dark theme colors and UI constants
public struct LightroomTheme {
    // Background tones
    public static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.12) // #1F1F1F
    public static let workspaceBackground = Color(red: 0.08, green: 0.08, blue: 0.08) // #141414
    public static let cardBackground = Color(red: 0.16, green: 0.16, blue: 0.16) // #292929
    public static let cardSelectedBackground = Color(red: 0.22, green: 0.22, blue: 0.22) // #383838
    public static let cardBorder = Color(red: 0.25, green: 0.25, blue: 0.25)
    public static let headerBackground = Color(red: 0.15, green: 0.15, blue: 0.15)
    public static let dividerColor = Color(red: 0.18, green: 0.18, blue: 0.18)
    
    // Accents & Highlights
    public static let accentYellow = Color(red: 0.95, green: 0.77, blue: 0.20) // #F2C433 (Lightroom Yellow)
    public static let accentBlue = Color(red: 0.16, green: 0.50, blue: 0.73) // #2980B9
    public static let selectionBorder = Color(red: 0.95, green: 0.77, blue: 0.20)
    
    // Text colors
    public static let textPrimary = Color(white: 0.90)
    public static let textSecondary = Color(white: 0.60)
    public static let textMuted = Color(white: 0.40)
    
    // Label colors
    public static func color(for label: ColorLabel) -> Color {
        switch label {
        case .none: return .clear
        case .red: return Color(red: 0.86, green: 0.24, blue: 0.24)
        case .yellow: return Color(red: 0.92, green: 0.71, blue: 0.16)
        case .green: return Color(red: 0.27, green: 0.72, blue: 0.35)
        case .blue: return Color(red: 0.20, green: 0.55, blue: 0.90)
        case .purple: return Color(red: 0.65, green: 0.35, blue: 0.85)
        }
    }
}
