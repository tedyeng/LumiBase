import Foundation
import CoreGraphics

/// Discovers and manages Adobe DCP (DNG Camera Profile) color calibration profiles
public final class DCPProfileManager: @unchecked Sendable {
    public static let shared = DCPProfileManager()
    
    private let standardDCPDirectory = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/CameraProfiles")
    
    public init() {}
    
    private let parser = DCPProfileParser.shared
    private let cacheLock = NSLock()
    private var cachedProfiles: [String: DCPProfile] = [:]
    
    /// Finds and parses the best matching Adobe DCP profile for a given camera model and requested profile name
    public func profile(for cameraModel: String?, requestedProfile: String? = nil) -> DCPProfile? {
        guard let model = cameraModel, !model.isEmpty else { return nil }
        let profileName = requestedProfile ?? "Adobe Standard"
        let key = "\(model)_\(profileName)"
        
        cacheLock.lock()
        if let cached = cachedProfiles[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        guard let url = locateDCPProfile(cameraModel: model, requestedProfile: profileName),
              let profile = parser.parse(url: url) else {
            return nil
        }
        
        cacheLock.lock()
        cachedProfiles[key] = profile
        cacheLock.unlock()
        return profile
    }
    
    /// Finds the best matching Adobe DCP profile for a given camera model and requested profile name
    public func locateDCPProfile(cameraModel: String?, requestedProfile: String? = nil) -> URL? {
        guard let model = cameraModel, !model.isEmpty else { return nil }
        
        let fileManager = FileManager.default
        let normalizedModel = normalizeCameraModel(model)
        let profileName = requestedProfile ?? "Adobe Standard"
        
        // 1. Try Adobe Standard folder: e.g. "Sony ILCE-7CM2 Adobe Standard.dcp"
        let adobeStandardDir = standardDCPDirectory.appendingPathComponent("Adobe Standard")
        let standardFilename = "\(normalizedModel) \(profileName).dcp"
        let standardPath = adobeStandardDir.appendingPathComponent(standardFilename)
        if fileManager.fileExists(atPath: standardPath.path) {
            return standardPath
        }
        
        // 2. Try direct camera model folder: e.g. "Camera/Sony ILCE-7CM2/Sony ILCE-7CM2 Camera ST.dcp"
        let cameraDir = standardDCPDirectory.appendingPathComponent("Camera").appendingPathComponent(normalizedModel)
        if fileManager.fileExists(atPath: cameraDir.path) {
            if let contents = try? fileManager.contentsOfDirectory(at: cameraDir, includingPropertiesForKeys: nil) {
                // Try to find matching profile or default to Camera ST / Standard
                if let match = contents.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(profileName) }) {
                    return match
                }
                if let defaultMatch = contents.first(where: { $0.lastPathComponent.hasSuffix(".dcp") }) {
                    return defaultMatch
                }
            }
        }
        
        // 3. Loose match in Adobe Standard directory
        if let contents = try? fileManager.contentsOfDirectory(at: adobeStandardDir, includingPropertiesForKeys: nil) {
            if let match = contents.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(model) }) {
                return match
            }
        }
        
        return nil
    }
    
    /// Normalizes raw EXIF model strings into Adobe's standardized naming conventions
    public func normalizeCameraModel(_ rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Sony cameras
        if trimmed.hasPrefix("ILCE-") || trimmed.hasPrefix("ILCA-") || trimmed.hasPrefix("ZV-") || trimmed.hasPrefix("NEX-") {
            return "Sony \(trimmed)"
        }
        if trimmed.hasPrefix("Sony ") {
            return trimmed
        }
        
        // Canon cameras
        if trimmed.hasPrefix("Canon ") {
            return trimmed
        }
        if trimmed.hasPrefix("EOS") || trimmed.hasPrefix("PowerShot") {
            return "Canon \(trimmed)"
        }
        
        // Nikon cameras
        if trimmed.hasPrefix("NIKON") || trimmed.hasPrefix("Nikon") {
            return trimmed
        }
        if trimmed.hasPrefix("Z ") || trimmed.hasPrefix("D") {
            return "Nikon \(trimmed)"
        }
        
        // Fujifilm
        if trimmed.hasPrefix("FUJIFILM") || trimmed.hasPrefix("Fujifilm") {
            return trimmed
        }
        if trimmed.hasPrefix("X-") || trimmed.hasPrefix("GFX") {
            return "Fujifilm \(trimmed)"
        }
        
        return trimmed
    }
    
    /// Adobe Standard PV2012 Film Tone Curve Control Points
    public var adobeStandardToneCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint) {
        return (
            p0: CGPoint(x: 0.0, y: 0.0),
            p1: CGPoint(x: 0.25, y: 0.175),
            p2: CGPoint(x: 0.50, y: 0.525),
            p3: CGPoint(x: 0.75, y: 0.850),
            p4: CGPoint(x: 1.0, y: 1.0)
        )
    }
}
