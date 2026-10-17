import Foundation

/// 8 Color Bands supported by Lightroom Classic HSL Mixer
public enum HSLColorBand: String, CaseIterable, Identifiable, Codable, Sendable {
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case aqua = "Aqua"
    case blue = "Blue"
    case purple = "Purple"
    case magenta = "Magenta"
    
    public var id: String { rawValue }
    
    /// Representative hue angle in degrees [0, 360)
    public var centerHue: Float {
        switch self {
        case .red: return 0.0
        case .orange: return 30.0
        case .yellow: return 60.0
        case .green: return 120.0
        case .aqua: return 180.0
        case .blue: return 240.0
        case .purple: return 275.0
        case .magenta: return 315.0
        }
    }
}

/// Represents individual Hue, Saturation, and Luminance adjustments for a color band
public struct HSLBandAdjustment: Codable, Equatable, Sendable {
    public var hue: Int = 0 // -100 to +100
    public var saturation: Int = 0 // -100 to +100
    public var luminance: Int = 0 // -100 to +100
    
    public init(hue: Int = 0, saturation: Int = 0, luminance: Int = 0) {
        self.hue = max(-100, min(100, hue))
        self.saturation = max(-100, min(100, saturation))
        self.luminance = max(-100, min(100, luminance))
    }
    
    public var isZero: Bool {
        hue == 0 && saturation == 0 && luminance == 0
    }
}

/// 8-Band Color Mixer adjustments matching Lightroom Classic
public struct HSLAdjustments: Codable, Equatable, Sendable {
    public var red: HSLBandAdjustment
    public var orange: HSLBandAdjustment
    public var yellow: HSLBandAdjustment
    public var green: HSLBandAdjustment
    public var aqua: HSLBandAdjustment
    public var blue: HSLBandAdjustment
    public var purple: HSLBandAdjustment
    public var magenta: HSLBandAdjustment
    
    public init(
        red: HSLBandAdjustment = HSLBandAdjustment(),
        orange: HSLBandAdjustment = HSLBandAdjustment(),
        yellow: HSLBandAdjustment = HSLBandAdjustment(),
        green: HSLBandAdjustment = HSLBandAdjustment(),
        aqua: HSLBandAdjustment = HSLBandAdjustment(),
        blue: HSLBandAdjustment = HSLBandAdjustment(),
        purple: HSLBandAdjustment = HSLBandAdjustment(),
        magenta: HSLBandAdjustment = HSLBandAdjustment()
    ) {
        self.red = red
        self.orange = orange
        self.yellow = yellow
        self.green = green
        self.aqua = aqua
        self.blue = blue
        self.purple = purple
        self.magenta = magenta
    }
    
    public subscript(band: HSLColorBand) -> HSLBandAdjustment {
        get {
            switch band {
            case .red: return red
            case .orange: return orange
            case .yellow: return yellow
            case .green: return green
            case .aqua: return aqua
            case .blue: return blue
            case .purple: return purple
            case .magenta: return magenta
            }
        }
        set {
            switch band {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }
    
    public var isZero: Bool {
        red.isZero && orange.isZero && yellow.isZero && green.isZero &&
        aqua.isZero && blue.isZero && purple.isZero && magenta.isZero
    }
    
    public var cacheIdentity: String {
        guard !isZero else { return "0" }
        return "\(red.hue),\(red.saturation),\(red.luminance);" +
               "\(orange.hue),\(orange.saturation),\(orange.luminance);" +
               "\(yellow.hue),\(yellow.saturation),\(yellow.luminance);" +
               "\(green.hue),\(green.saturation),\(green.luminance);" +
               "\(aqua.hue),\(aqua.saturation),\(aqua.luminance);" +
               "\(blue.hue),\(blue.saturation),\(blue.luminance);" +
               "\(purple.hue),\(purple.saturation),\(purple.luminance);" +
               "\(magenta.hue),\(magenta.saturation),\(magenta.luminance)"
    }
    
    public static let zero = HSLAdjustments()
}
