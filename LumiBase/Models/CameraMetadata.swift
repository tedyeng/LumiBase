import Foundation

/// Extracted camera, lens, and exposure parameters from RAW / EXIF metadata
public struct CameraMetadata: Codable, Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var lensModel: String?
    public var focalLength: Double? // in mm (e.g. 35.0)
    public var focalLength35mm: Double? // 35mm equivalent
    public var aperture: Double? // f-number (e.g. 1.8, 2.8)
    public var shutterSpeed: String? // formatted (e.g. "1/250s", "2.5s")
    public var shutterSpeedValue: Double? // in seconds (e.g. 0.004)
    public var iso: Int? // e.g. 100, 800, 3200
    public var exposureCompensation: Double? // EV (e.g. +0.3, -1.0)
    public var flashFired: Bool?
    public var whiteBalance: String? // "Auto", "Daylight", "Custom", etc.
    public var meteringMode: String?
    public var captureDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var colorSpace: String?
    public var fileFormat: String?
    
    public init(
        make: String? = nil,
        model: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        focalLength35mm: Double? = nil,
        aperture: Double? = nil,
        shutterSpeed: String? = nil,
        shutterSpeedValue: Double? = nil,
        iso: Int? = nil,
        exposureCompensation: Double? = nil,
        flashFired: Bool? = nil,
        whiteBalance: String? = nil,
        meteringMode: String? = nil,
        captureDate: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        colorSpace: String? = nil,
        fileFormat: String? = nil
    ) {
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.focalLength35mm = focalLength35mm
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.shutterSpeedValue = shutterSpeedValue
        self.iso = iso
        self.exposureCompensation = exposureCompensation
        self.flashFired = flashFired
        self.whiteBalance = whiteBalance
        self.meteringMode = meteringMode
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorSpace = colorSpace
        self.fileFormat = fileFormat
    }
    
    /// Formatted exposure summary string (e.g. "35mm • f/1.8 • 1/250s • ISO 100")
    public var exposureSummary: String {
        var parts: [String] = []
        if let focal = focalLength {
            parts.append(String(format: "%.0f mm", focal))
        }
        if let f = aperture {
            parts.append(String(format: "ƒ/%.1f", f))
        }
        if let s = shutterSpeed {
            parts.append(s)
        }
        if let isoVal = iso {
            parts.append("ISO \(isoVal)")
        }
        return parts.joined(separator: "  •  ")
    }
    
    public static let empty = CameraMetadata()
}
