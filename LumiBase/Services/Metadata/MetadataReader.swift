import Foundation
import ImageIO
import CoreGraphics

/// Reads EXIF, TIFF, and RAW image properties directly using Apple ImageIO
public final class MetadataReader: Sendable {
    
    /// Extract CameraMetadata and any embedded XMP metadata from an image file
    public static func readMetadata(from url: URL) -> (camera: CameraMetadata, embeddedXMP: XMPMetadata?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return (.empty, nil)
        }
        
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        
        let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        
        // Make & Model
        let make = tiffDict[kCGImagePropertyTIFFMake as String] as? String
        let model = tiffDict[kCGImagePropertyTIFFModel as String] as? String
        
        // Dimensions
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int
        let colorSpace = properties[kCGImagePropertyColorModel as String] as? String
        
        // Lens info
        let lensModel = exifDict[kCGImagePropertyExifLensModel as String] as? String
        
        // Focal Length
        let focalLength = exifDict[kCGImagePropertyExifFocalLength as String] as? Double
        let focalLength35mm = (exifDict[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double)
            ?? (exifDict[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int).map { Double($0) }
        
        // Aperture (F-Number)
        let aperture = exifDict[kCGImagePropertyExifFNumber as String] as? Double
        
        // Shutter Speed / Exposure Time
        var shutterSpeedFormatted: String?
        var shutterSpeedVal: Double?
        if let exposureTime = exifDict[kCGImagePropertyExifExposureTime as String] as? Double {
            shutterSpeedVal = exposureTime
            if exposureTime >= 1.0 {
                shutterSpeedFormatted = String(format: "%.1fs", exposureTime)
            } else if exposureTime > 0 {
                let denominator = Int(round(1.0 / exposureTime))
                shutterSpeedFormatted = "1/\(denominator)s"
            }
        }
        
        // ISO
        var iso: Int?
        if let isoArray = exifDict[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let first = isoArray.first {
            iso = first
        } else if let isoArray = exifDict[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let first = isoArray.first {
            iso = first.intValue
        } else if let isoNum = exifDict[kCGImagePropertyExifISOSpeedRatings as String] as? Int {
            iso = isoNum
        }
        
        // Exposure Compensation
        let exposureComp = exifDict[kCGImagePropertyExifExposureBiasValue as String] as? Double
        
        // Flash
        let flashFired: Bool?
        if let flashValue = exifDict[kCGImagePropertyExifFlash as String] as? Int {
            flashFired = (flashValue & 1) != 0
        } else {
            flashFired = nil
        }
        
        // White balance
        let whiteBalance: String?
        if let wb = exifDict[kCGImagePropertyExifWhiteBalance as String] as? Int {
            whiteBalance = wb == 0 ? "Auto" : "Manual"
        } else {
            whiteBalance = nil
        }
        
        // Metering Mode
        var meteringMode: String?
        if let mm = exifDict[kCGImagePropertyExifMeteringMode as String] as? Int {
            switch mm {
            case 1: meteringMode = "Average"
            case 2: meteringMode = "Center Weighted Average"
            case 3: meteringMode = "Spot"
            case 4: meteringMode = "Multi-Spot"
            case 5: meteringMode = "Pattern"
            case 6: meteringMode = "Partial"
            default: meteringMode = nil
            }
        }
        
        // Capture Date
        var captureDate: Date?
        let dateString = (exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiffDict[kCGImagePropertyTIFFDateTime as String] as? String)
        
        if let dateStr = dateString {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = TimeZone.current
            captureDate = formatter.date(from: dateStr)
        }
        
        let camera = CameraMetadata(
            make: make?.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines),
            lensModel: lensModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            focalLength: focalLength,
            focalLength35mm: focalLength35mm,
            aperture: aperture,
            shutterSpeed: shutterSpeedFormatted,
            shutterSpeedValue: shutterSpeedVal,
            iso: iso,
            exposureCompensation: exposureComp,
            flashFired: flashFired,
            whiteBalance: whiteBalance,
            meteringMode: meteringMode,
            captureDate: captureDate,
            pixelWidth: width,
            pixelHeight: height,
            colorSpace: colorSpace,
            fileFormat: url.pathExtension.uppercased()
        )
        
        // Check for embedded XMP
        var embeddedXMP: XMPMetadata?
        if let typeIdentifier = CGImageSourceGetType(source) as String?,
           typeIdentifier.contains("dng") || typeIdentifier.contains("tiff") || typeIdentifier.contains("jpeg") {
            // Check if XMP properties exist in aux / xmp dictionaries
            if let xmpData = properties["{XMP}"] as? [String: Any] {
                // If embedded rating exists
                let rating = xmpData["Rating"] as? Int ?? 0
                if rating > 0 {
                    embeddedXMP = XMPMetadata(rating: rating)
                }
            }
        }
        
        return (camera, embeddedXMP)
    }
}
