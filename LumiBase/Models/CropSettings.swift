import Foundation
import CoreGraphics

/// Active tool mode in Lightroom Develop panel
public enum DevelopToolMode: String, CaseIterable, Sendable {
    case edit = "Edit"
    case crop = "Crop"
}

/// Crop overlay grid styles matching Lightroom Classic (cycled with O key)
public enum CropOverlayStyle: String, CaseIterable, Identifiable, Sendable {
    case grid = "Grid"
    case thirds = "Thirds"
    
    public var id: String { rawValue }
    public var displayName: String { rawValue }
}

/// Standard Lightroom aspect ratio presets
public enum CropAspectRatioPreset: String, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case custom = "Custom"
    case square1x1 = "1 : 1"
    case ratio4x5 = "4 : 5 (8x10)"
    case ratio5x7 = "5 : 7"
    case ratio16x9 = "16 : 9"
    
    public var id: String { rawValue }
    
    public var displayName: String { rawValue }
    
    /// Returns the target width / height ratio if fixed, or nil for custom
    public func ratio(originalWidth: CGFloat, originalHeight: CGFloat) -> CGFloat? {
        switch self {
        case .original:
            guard originalHeight > 0 else { return 3.0 / 2.0 }
            return originalWidth / originalHeight
        case .custom:
            return nil
        case .square1x1:
            return 1.0
        case .ratio4x5:
            return 4.0 / 5.0
        case .ratio5x7:
            return 5.0 / 7.0
        case .ratio16x9:
            return 16.0 / 9.0
        }
    }
}

/// Represents normalized crop coordinates (0.0 to 1.0) and rotation angle
public struct CropGeometry: Equatable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double
    public var angle: Double // in degrees (-45.0 to +45.0)
    
    public init(
        top: Double = 0.0,
        left: Double = 0.0,
        bottom: Double = 1.0,
        right: Double = 1.0,
        angle: Double = 0.0
    ) {
        self.top = max(0.0, min(1.0, top))
        self.left = max(0.0, min(1.0, left))
        self.bottom = max(0.0, min(1.0, bottom))
        self.right = max(0.0, min(1.0, right))
        self.angle = max(-45.0, min(45.0, angle))
    }
    
    public var isDefault: Bool {
        top == 0.0 && left == 0.0 && bottom == 1.0 && right == 1.0 && angle == 0.0
    }
    
    public var widthFraction: Double {
        max(0.01, right - left)
    }
    
    public var heightFraction: Double {
        max(0.01, bottom - top)
    }
    
    public static let full = CropGeometry(top: 0.0, left: 0.0, bottom: 1.0, right: 1.0, angle: 0.0)
}
