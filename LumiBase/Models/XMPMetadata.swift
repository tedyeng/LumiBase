import Foundation

/// Represents the flag status of a photo (Pick, Reject, or None)
public enum FlagStatus: String, Codable, CaseIterable, Sendable {
    case unflagged = "unflagged"
    case pick = "pick"
    case reject = "reject"
}

/// Represents Lightroom color labels
public enum ColorLabel: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }
}

/// Metadata stored in and parsed from XMP sidecar files
public struct XMPMetadata: Codable, Equatable, Sendable {
    public var isLoadedFromSidecar: Bool
    public var sidecarFilename: String?
    
    // DAM Fields
    public var rating: Int // 0 to 5
    public var colorLabel: ColorLabel
    public var flag: FlagStatus
    public var keywords: [String]
    public var title: String?
    public var caption: String?
    public var creator: String?
    public var copyright: String?
    public var ratingDate: Date?
    
    // Lightroom / Camera RAW Develop Settings
    public var exposure2012: Double?
    public var temperature: Int?
    public var tint: Int?
    public var contrast2012: Int?
    public var highlights2012: Int?
    public var shadows2012: Int?
    public var whites2012: Int?
    public var blacks2012: Int?
    public var dehaze: Int?
    public var vibrance: Int?
    public var saturation: Int?
    public var clarity2012: Int?
    public var texture: Int?
    public var cropTop: Double?
    public var cropLeft: Double?
    public var cropBottom: Double?
    public var cropRight: Double?
    public var cropAngle: Double?
    public var cameraProfile: String?
    public var convertToGrayscale: Bool?
    private var _hasCrop: Bool = false
    
    public var hasCrop: Bool {
        get {
            let top = cropTop ?? 0.0
            let left = cropLeft ?? 0.0
            let bottom = cropBottom ?? 1.0
            let right = cropRight ?? 1.0
            let angle = cropAngle ?? 0.0
            return _hasCrop || top > 0.0001 || left > 0.0001 || bottom < 0.9999 || right < 0.9999 || abs(angle) > 0.0001
        }
        set {
            _hasCrop = newValue
            if !newValue {
                cropTop = nil
                cropLeft = nil
                cropBottom = nil
                cropRight = nil
                cropAngle = nil
            }
        }
    }
    
    public init(
        isLoadedFromSidecar: Bool = false,
        sidecarFilename: String? = nil,
        rating: Int = 0,
        colorLabel: ColorLabel = .none,
        flag: FlagStatus = .unflagged,
        keywords: [String] = [],
        title: String? = nil,
        caption: String? = nil,
        creator: String? = nil,
        copyright: String? = nil,
        ratingDate: Date? = nil,
        exposure2012: Double? = nil,
        temperature: Int? = nil,
        tint: Int? = nil,
        contrast2012: Int? = nil,
        highlights2012: Int? = nil,
        shadows2012: Int? = nil,
        whites2012: Int? = nil,
        blacks2012: Int? = nil,
        dehaze: Int? = nil,
        vibrance: Int? = nil,
        saturation: Int? = nil,
        clarity2012: Int? = nil,
        texture: Int? = nil,
        hasCrop: Bool = false,
        cropTop: Double? = nil,
        cropLeft: Double? = nil,
        cropBottom: Double? = nil,
        cropRight: Double? = nil,
        cropAngle: Double? = nil,
        cameraProfile: String? = nil,
        convertToGrayscale: Bool? = nil
    ) {
        self.isLoadedFromSidecar = isLoadedFromSidecar
        self.sidecarFilename = sidecarFilename
        self.rating = max(0, min(5, rating))
        self.colorLabel = colorLabel
        self.flag = flag
        self.keywords = keywords
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
        self.ratingDate = ratingDate
        self.exposure2012 = exposure2012
        self.temperature = temperature
        self.tint = tint
        self.contrast2012 = contrast2012
        self.highlights2012 = highlights2012
        self.shadows2012 = shadows2012
        self.whites2012 = whites2012
        self.blacks2012 = blacks2012
        self.dehaze = dehaze
        self.vibrance = vibrance
        self.saturation = saturation
        self.clarity2012 = clarity2012
        self.texture = texture
        self._hasCrop = hasCrop
        self.cropTop = cropTop
        self.cropLeft = cropLeft
        self.cropBottom = cropBottom
        self.cropRight = cropRight
        self.cropAngle = cropAngle
        self.cameraProfile = cameraProfile
        self.convertToGrayscale = convertToGrayscale
    }
    
    public var cropGeometry: CropGeometry {
        get {
            CropGeometry(
                top: cropTop ?? 0.0,
                left: cropLeft ?? 0.0,
                bottom: cropBottom ?? 1.0,
                right: cropRight ?? 1.0,
                angle: cropAngle ?? 0.0
            )
        }
        set {
            if newValue.isDefault {
                cropTop = nil
                cropLeft = nil
                cropBottom = nil
                cropRight = nil
                cropAngle = nil
                _hasCrop = false
            } else {
                cropTop = newValue.top
                cropLeft = newValue.left
                cropBottom = newValue.bottom
                cropRight = newValue.right
                cropAngle = (newValue.angle != 0.0) ? newValue.angle : nil
                _hasCrop = true
            }
        }
    }
    
    public mutating func resetCrop() {
        cropTop = nil
        cropLeft = nil
        cropBottom = nil
        cropRight = nil
        cropAngle = nil
        _hasCrop = false
    }
    
    public var hasDevelopEdits: Bool {
        (exposure2012 != nil && exposure2012 != 0.0) ||
        (temperature != nil && temperature != 0) ||
        (tint != nil && tint != 0) ||
        (contrast2012 != nil && contrast2012 != 0) ||
        (highlights2012 != nil && highlights2012 != 0) ||
        (shadows2012 != nil && shadows2012 != 0) ||
        (whites2012 != nil && whites2012 != 0) ||
        (blacks2012 != nil && blacks2012 != 0) ||
        (dehaze != nil && dehaze != 0) ||
        (vibrance != nil && vibrance != 0) ||
        (saturation != nil && saturation != 0) ||
        (clarity2012 != nil && clarity2012 != 0) ||
        (texture != nil && texture != 0) ||
        (convertToGrayscale == true) ||
        hasCrop
    }

    /// Stable identity for every develop value that can affect rendered thumbnail pixels.
    /// Optional markers keep this independent of locale and avoid ambiguous concatenation.
    var thumbnailDevelopCacheIdentity: String {
        func integer(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        func decimal(_ value: Double?) -> String {
            guard let value else { return "-" }
            return String(value.bitPattern, radix: 16)
        }
        func string(_ value: String?) -> String {
            guard let value else { return "-" }
            return "\(value.utf8.count):\(value)"
        }
        return [
            "exposure=\(decimal(exposure2012))", "temperature=\(integer(temperature))",
            "tint=\(integer(tint))", "contrast=\(integer(contrast2012))",
            "highlights=\(integer(highlights2012))", "shadows=\(integer(shadows2012))",
            "whites=\(integer(whites2012))", "blacks=\(integer(blacks2012))",
            "dehaze=\(integer(dehaze))", "vibrance=\(integer(vibrance))",
            "saturation=\(integer(saturation))", "clarity=\(integer(clarity2012))",
            "texture=\(integer(texture))",
            "crop=\(hasCrop ? 1 : 0):\(decimal(cropTop)):\(decimal(cropLeft)):\(decimal(cropBottom)):\(decimal(cropRight)):\(decimal(cropAngle))",
            "profile=\(string(cameraProfile))", "grayscale=\(convertToGrayscale.map { $0 ? 1 : 0 } ?? -1)"
        ].joined(separator: "|")
    }
    
    /// Resets all develop (Basic) settings to camera default / zero
    public mutating func resetDevelopSettings() {
        exposure2012 = nil
        temperature = nil
        tint = nil
        contrast2012 = nil
        highlights2012 = nil
        shadows2012 = nil
        whites2012 = nil
        blacks2012 = nil
        dehaze = nil
        vibrance = nil
        saturation = nil
        clarity2012 = nil
        texture = nil
        convertToGrayscale = nil
        resetCrop()
    }
    
    public static let empty = XMPMetadata()
}
