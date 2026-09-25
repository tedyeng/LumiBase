import Foundation

/// Defines which develop settings to copy or synchronize between photos, matching Lightroom Classic's Sync / Copy Settings model.
public struct DevelopSyncOptions: Codable, Equatable, Sendable {
    // White Balance
    public var whiteBalance: Bool
    
    // Basic Tone
    public var exposure: Bool
    public var contrast: Bool
    public var highlights: Bool
    public var shadows: Bool
    public var whites: Bool
    public var blacks: Bool
    
    // Presence
    public var texture: Bool
    public var clarity: Bool
    public var dehaze: Bool
    public var vibrance: Bool
    public var saturation: Bool
    
    // Treatment & Profile
    public var cameraProfile: Bool
    public var treatment: Bool // ConvertToGrayscale / Black & White
    
    // Geometry
    public var crop: Bool
    
    public init(
        whiteBalance: Bool = true,
        exposure: Bool = true,
        contrast: Bool = true,
        highlights: Bool = true,
        shadows: Bool = true,
        whites: Bool = true,
        blacks: Bool = true,
        texture: Bool = true,
        clarity: Bool = true,
        dehaze: Bool = true,
        vibrance: Bool = true,
        saturation: Bool = true,
        cameraProfile: Bool = true,
        treatment: Bool = true,
        crop: Bool = false // In Lightroom Classic, crop is unchecked by default
    ) {
        self.whiteBalance = whiteBalance
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.vibrance = vibrance
        self.saturation = saturation
        self.cameraProfile = cameraProfile
        self.treatment = treatment
        self.crop = crop
    }
    
    // MARK: - Group Helpers
    
    public var allToneEnabled: Bool {
        exposure && contrast && highlights && shadows && whites && blacks
    }
    
    public var anyToneEnabled: Bool {
        exposure || contrast || highlights || shadows || whites || blacks
    }
    
    public mutating func setAllTone(_ enabled: Bool) {
        exposure = enabled
        contrast = enabled
        highlights = enabled
        shadows = enabled
        whites = enabled
        blacks = enabled
    }
    
    public var allPresenceEnabled: Bool {
        texture && clarity && dehaze && vibrance && saturation
    }
    
    public var anyPresenceEnabled: Bool {
        texture || clarity || dehaze || vibrance || saturation
    }
    
    public mutating func setAllPresence(_ enabled: Bool) {
        texture = enabled
        clarity = enabled
        dehaze = enabled
        vibrance = enabled
        saturation = enabled
    }
    
    public var hasAnySelected: Bool {
        whiteBalance || exposure || contrast || highlights || shadows || whites || blacks ||
        texture || clarity || dehaze || vibrance || saturation || cameraProfile || treatment || crop
    }
    
    public mutating func checkAll(includeCrop: Bool = false) {
        whiteBalance = true
        setAllTone(true)
        setAllPresence(true)
        cameraProfile = true
        treatment = true
        crop = includeCrop
    }
    
    public mutating func checkNone() {
        whiteBalance = false
        setAllTone(false)
        setAllPresence(false)
        cameraProfile = false
        treatment = false
        crop = false
    }
    
    /// Preselects only the options that have actual non-default / non-nil adjustments in the source metadata
    public mutating func checkModified(from source: XMPMetadata) {
        whiteBalance = (source.temperature != nil && source.temperature != 0) || (source.tint != nil && source.tint != 0)
        exposure = (source.exposure2012 != nil && source.exposure2012 != 0.0)
        contrast = (source.contrast2012 != nil && source.contrast2012 != 0)
        highlights = (source.highlights2012 != nil && source.highlights2012 != 0)
        shadows = (source.shadows2012 != nil && source.shadows2012 != 0)
        whites = (source.whites2012 != nil && source.whites2012 != 0)
        blacks = (source.blacks2012 != nil && source.blacks2012 != 0)
        
        texture = (source.texture != nil && source.texture != 0)
        clarity = (source.clarity2012 != nil && source.clarity2012 != 0)
        dehaze = (source.dehaze != nil && source.dehaze != 0)
        vibrance = (source.vibrance != nil && source.vibrance != 0)
        saturation = (source.saturation != nil && source.saturation != 0)
        
        cameraProfile = (source.cameraProfile != nil)
        treatment = (source.convertToGrayscale != nil)
        crop = source.hasCrop
    }
    
    // MARK: - Application Logic
    
    /// Copies selected fields from the source metadata to the target metadata
    public func apply(from source: XMPMetadata, to target: inout XMPMetadata) {
        if whiteBalance {
            target.temperature = source.temperature
            target.tint = source.tint
        }
        
        if exposure {
            target.exposure2012 = source.exposure2012
        }
        if contrast {
            target.contrast2012 = source.contrast2012
        }
        if highlights {
            target.highlights2012 = source.highlights2012
        }
        if shadows {
            target.shadows2012 = source.shadows2012
        }
        if whites {
            target.whites2012 = source.whites2012
        }
        if blacks {
            target.blacks2012 = source.blacks2012
        }
        
        if texture {
            target.texture = source.texture
        }
        if clarity {
            target.clarity2012 = source.clarity2012
        }
        if dehaze {
            target.dehaze = source.dehaze
        }
        if vibrance {
            target.vibrance = source.vibrance
        }
        if saturation {
            target.saturation = source.saturation
        }
        
        if cameraProfile {
            target.cameraProfile = source.cameraProfile
        }
        if treatment {
            target.convertToGrayscale = source.convertToGrayscale
        }
        
        if crop {
            target.hasCrop = source.hasCrop
            target.cropTop = source.cropTop
            target.cropLeft = source.cropLeft
            target.cropBottom = source.cropBottom
            target.cropRight = source.cropRight
            target.cropAngle = source.cropAngle
        }
    }
    
    public static let `default` = DevelopSyncOptions()
}
