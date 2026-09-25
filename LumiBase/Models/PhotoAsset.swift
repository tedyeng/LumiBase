import Foundation

/// Supported RAW and Image file extensions
public enum SupportedFileType: String, CaseIterable {
    // RAW Formats
    case arw = "arw" // Sony
    case cr2 = "cr2" // Canon
    case cr3 = "cr3" // Canon
    case nef = "nef" // Nikon
    case dng = "dng" // Adobe Digital Negative / Leica / DJI / Apple ProRAW
    case raf = "raf" // Fujifilm
    case rw2 = "rw2" // Panasonic
    case orf = "orf" // Olympus / OM System
    case pef = "pef" // Pentax
    
    // Standard Raster Formats
    case jpg = "jpg"
    case jpeg = "jpeg"
    case tiff = "tiff"
    case tif = "tif"
    case heic = "heic"
    case png = "png"
    
    public var isRaw: Bool {
        switch self {
        case .arw, .cr2, .cr3, .nef, .dng, .raf, .rw2, .orf, .pef:
            return true
        default:
            return false
        }
    }
    
    public static var allExtensions: Set<String> {
        Set(Self.allCases.map { $0.rawValue })
    }
}

/// Represents a single image asset on disk with its associated metadata and XMP sidecar
public struct PhotoAsset: Identifiable, Hashable, Sendable {
    public var id: String {
        fileURL.standardizedFileURL.path
    }
    public let fileURL: URL
    public let filename: String
    public let fileExtension: String
    public let fileSize: Int64
    public let dateModified: Date
    public let dateCreated: Date
    /// EXIF/TIFF orientation captured during metadata scanning; nil means it is not verified.
    public let sourceOrientation: Int?
    
    public var isRaw: Bool {
        SupportedFileType(rawValue: fileExtension.lowercased())?.isRaw ?? false
    }
    
    /// Expected XMP sidecar file URL (e.g. "DSC01234.ARW.xmp" or "DSC01234.xmp")
    public var sidecarXMPURL: URL {
        let parentDir = fileURL.deletingLastPathComponent()
        let directXmp = parentDir.appendingPathComponent("\(fileURL.lastPathComponent).xmp")
        let baseNameXmp = parentDir.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).xmp")
        
        if FileManager.default.fileExists(atPath: directXmp.path) {
            return directXmp
        }
        return baseNameXmp
    }
    
    public var hasSidecarXMP: Bool {
        let parentDir = fileURL.deletingLastPathComponent()
        let directXmp = parentDir.appendingPathComponent("\(fileURL.lastPathComponent).xmp")
        let baseNameXmp = parentDir.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).xmp")
        return FileManager.default.fileExists(atPath: directXmp.path) || FileManager.default.fileExists(atPath: baseNameXmp.path)
    }
    
    public var companionURLs: [URL]
    
    public var hasCompanionJPG: Bool {
        companionURLs.contains { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }
    
    public var isRawPlusJPG: Bool {
        isRaw && hasCompanionJPG
    }
    
    public var formatBadgeText: String {
        if isRawPlusJPG {
            return "RAW+JPG"
        }
        return fileExtension.uppercased()
    }
    
    /// Collects all associated files on disk for this asset (primary file, companion files, and XMP sidecars)
    public var allAssociatedURLs: [URL] {
        var urls: [URL] = [fileURL]
        urls.append(contentsOf: companionURLs)
        
        let parentDir = fileURL.deletingLastPathComponent()
        let directXmp = parentDir.appendingPathComponent("\(fileURL.lastPathComponent).xmp")
        let baseNameXmp = parentDir.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).xmp")
        
        if FileManager.default.fileExists(atPath: directXmp.path) && !urls.contains(directXmp) {
            urls.append(directXmp)
        }
        if FileManager.default.fileExists(atPath: baseNameXmp.path) && !urls.contains(baseNameXmp) {
            urls.append(baseNameXmp)
        }
        
        for companion in companionURLs {
            let companionDirectXmp = parentDir.appendingPathComponent("\(companion.lastPathComponent).xmp")
            if FileManager.default.fileExists(atPath: companionDirectXmp.path) && !urls.contains(companionDirectXmp) {
                urls.append(companionDirectXmp)
            }
        }
        
        return urls
    }
    
    public var xmp: XMPMetadata
    public var cameraMetadata: CameraMetadata
    
    public init(
        fileURL: URL,
        fileSize: Int64 = 0,
        dateModified: Date = Date(),
        dateCreated: Date = Date(),
        sourceOrientation: Int? = nil,
        companionURLs: [URL] = [],
        xmp: XMPMetadata = .empty,
        cameraMetadata: CameraMetadata = .empty
    ) {
        self.fileURL = fileURL
        self.filename = fileURL.lastPathComponent
        self.fileExtension = fileURL.pathExtension.lowercased()
        self.fileSize = fileSize
        self.dateModified = dateModified
        self.dateCreated = dateCreated
        self.sourceOrientation = sourceOrientation
        self.companionURLs = companionURLs
        self.xmp = xmp
        self.cameraMetadata = cameraMetadata
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(companionURLs)
        hasher.combine(sourceOrientation)
    }
    
    public static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id && lhs.companionURLs == rhs.companionURLs && lhs.xmp == rhs.xmp && lhs.cameraMetadata == rhs.cameraMetadata && lhs.sourceOrientation == rhs.sourceOrientation
    }
}
