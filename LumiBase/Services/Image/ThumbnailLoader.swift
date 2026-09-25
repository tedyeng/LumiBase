import Foundation
import AppKit
import CoreImage
import ImageIO

/// High-performance thumbnail extractor utilizing ImageIO embedded JPEG previews
public actor ThumbnailLoader {
    public static let shared = ThumbnailLoader()
    
    private let cache = ThumbnailCacheManager.shared
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]

    /// Returns only an already resident thumbnail; safe for the synchronous selection handoff.
    public nonisolated static func cachedMemoryThumbnail(for asset: PhotoAsset, maxPixelSize: Int = 1600) -> NSImage? {
        let cache = ThumbnailCacheManager.shared
        return cache.memoryImage(forKey: cacheKey(for: asset, maxPixelSize: maxPixelSize))
    }

    /// The single key path used by insertion/loading and synchronous handoff.
    static func cacheKey(for asset: PhotoAsset, maxPixelSize: Int) -> String {
        ThumbnailCacheManager.shared.cacheKey(for: asset.fileURL, maxPixelSize: maxPixelSize,
            dateModified: asset.dateModified, developTag: asset.xmp.thumbnailDevelopCacheIdentity)
    }
    
    /// Loads a thumbnail asynchronously with memory/disk caching and request deduplication
    public func loadThumbnail(for asset: PhotoAsset, maxPixelSize: Int = 400) async -> NSImage? {
        let key = Self.cacheKey(for: asset, maxPixelSize: maxPixelSize)
        
        // Check cache first
        if let cached = cache.image(forKey: key) {
            return cached
        }
        
        // Deduplicate in-flight requests
        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }
        
        let targetAsset = asset
        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            return Self.createThumbnail(for: targetAsset, maxPixelSize: maxPixelSize)
        }
        
        inFlightTasks[key] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: key)
        
        if let thumbnail = result {
            cache.store(image: thumbnail, forKey: key)
        }
        
        return result
    }
    
    /// Synchronously creates a thumbnail from disk using CIRAWFilter draft mode (for exact preview match) or ImageIO
    private nonisolated static func createThumbnail(for asset: PhotoAsset, maxPixelSize: Int) -> NSImage? {
        // 1. For RAW assets with develop edits, use CIRAWFilter to get identical color science as Loupe View
        if asset.isRaw && asset.xmp.hasDevelopEdits {
            if let rawFilter = CIRAWFilter(imageURL: asset.fileURL) {
                if let baseCI = rawFilter.outputImage {
                    let processed = AdobeColorPipeline.shared.process(
                        image: baseCI,
                        cameraModel: asset.cameraMetadata.model,
                        xmp: asset.xmp
                    )
                    let extent = processed.extent
                    let maxDim = max(extent.width, extent.height)
                    let scale = maxDim > CGFloat(maxPixelSize) ? CGFloat(maxPixelSize) / maxDim : 1.0
                    let scaledCI = scale < 1.0 ? processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : processed
                    
                    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
                    if let renderedCG = ciContext.createCGImage(scaledCI, from: scaledCI.extent) {
                        let size = NSSize(width: renderedCG.width, height: renderedCG.height)
                        return NSImage(cgImage: renderedCG, size: size)
                    }
                }
            }
            // An edited RAW may display only a completed processed render. Never relabel its
            // embedded, unedited JPEG as though it reflected the active develop settings.
            return nil
        }
        
        // 2. Standard fast path using ImageIO embedded preview
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}
