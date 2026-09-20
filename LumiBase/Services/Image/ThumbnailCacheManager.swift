import Foundation
import AppKit
import CryptoKit

/// Thread-safe two-tier thumbnail caching (Memory + Disk)
public final class ThumbnailCacheManager: @unchecked Sendable {
    public static let shared = ThumbnailCacheManager()
    
    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskCacheURL: URL
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.lumibase.cache.io", qos: .utility)
    
    private init() {
        // Configure memory cache (limit to ~200MB / 1000 thumbnails)
        memoryCache.countLimit = 1500
        memoryCache.totalCostLimit = 250 * 1024 * 1024 // 250MB
        
        // Setup disk cache in Application Support / Caches / LumiBase (versioned)
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = cachesDirectory.appendingPathComponent("com.lumibase.thumbnails.v3", isDirectory: true)
        
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }
    
    /// Generates a unique cache key based on file URL, modification date, and XMP develop edits
    public func cacheKey(for url: URL, maxPixelSize: Int, dateModified: Date, developTag: String = "") -> String {
        let rawKey = "\(url.standardizedFileURL.path)_\(dateModified.timeIntervalSince1970)_\(maxPixelSize)_\(developTag)"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    /// Retrieves a cached image from memory or disk
    public func image(forKey key: String) -> NSImage? {
        // 1. Check memory cache
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }
        
        // 2. Check disk cache
        let diskURL = diskCacheURL.appendingPathComponent("\(key).jpg")
        if let diskData = try? Data(contentsOf: diskURL),
           let diskImage = NSImage(data: diskData) {
            // Populate memory cache
            let cost = Int(diskImage.size.width * diskImage.size.height * 4)
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            return diskImage
        }
        
        return nil
    }
    
    /// Stores an image in memory and asynchronously persists to disk
    public func store(image: NSImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let diskURL = self.diskCacheURL.appendingPathComponent("\(key).jpg")
            if !self.fileManager.fileExists(atPath: diskURL.path),
               let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? jpegData.write(to: diskURL, options: .atomic)
            }
        }
    }
    
    /// Clears both memory and disk caches
    public func clearCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }
}
