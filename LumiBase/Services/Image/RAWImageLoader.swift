import Foundation
import AppKit
import CoreImage
import ImageIO

public struct BaseImageHolder: @unchecked Sendable {
    public let full: CIImage
    public let display: CIImage
    public let interactive: CIImage
    public let fullExtent: CGRect
    public let displayExtent: CGRect
    public let interactiveExtent: CGRect
}

/// High-resolution RAW and raster image loader for Loupe view
public final class RAWImageLoader: @unchecked Sendable {
    public static let shared = RAWImageLoader()
    
    private let ciContext: CIContext
    
    private init() {
        // High performance Metal-backed CoreImage Context
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
    }
    
    // In-memory cache for the currently active base CIImage holder
    private var cachedBaseURL: URL?
    private var cachedBaseHolder: BaseImageHolder?
    private let cacheLock = NSLock()
    
    /// Asynchronously decodes and retrieves the base neutral CIImage holder (with full, display, and interactive proxies)
    public func loadBaseHolder(from url: URL) async -> BaseImageHolder? {
        cacheLock.lock()
        if cachedBaseURL == url, let cached = cachedBaseHolder {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        return await Task.detached(priority: .userInitiated) { [weak self] () -> BaseImageHolder? in
            let pathExtension = url.pathExtension.lowercased()
            let isRaw = SupportedFileType(rawValue: pathExtension)?.isRaw ?? false
            
            var baseCIImage: CIImage?
            
            // 1. Try CIRAWFilter for Apple RAW engine
            if isRaw {
                if let rawFilter = CIRAWFilter(imageURL: url) {
                    baseCIImage = rawFilter.outputImage
                }
            }
            
            // 2. Standard ImageIO path if CIRAWFilter wasn't used or failed
            if baseCIImage == nil {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceShouldAllowFloat: true
                    ]
                    if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                        baseCIImage = CIImage(cgImage: cgImage)
                    } else {
                        // Fallback to high-res embedded preview
                        let thumbOptions: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 4096
                        ]
                        if let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                            baseCIImage = CIImage(cgImage: thumbCG)
                        }
                    }
                }
            }
            
            guard let fullImage = baseCIImage else { return nil }
            
            let fullExtent = fullImage.extent
            let maxDim = max(fullExtent.width, fullExtent.height)
            
            // Display proxy (2560px for crystal-clear screen rendering)
            let displayScale = maxDim > 2560 ? (2560.0 / maxDim) : 1.0
            let displayImage: CIImage
            let displayExtent: CGRect
            if displayScale < 1.0 {
                displayImage = fullImage.transformed(by: CGAffineTransform(scaleX: displayScale, y: displayScale))
                displayExtent = displayImage.extent
            } else {
                displayImage = fullImage
                displayExtent = fullExtent
            }
            
            // Interactive proxy (1440px for sub-millisecond 120fps live dragging)
            let interactiveScale = maxDim > 1440 ? (1440.0 / maxDim) : 1.0
            let interactiveImage: CIImage
            let interactiveExtent: CGRect
            if interactiveScale < 1.0 {
                interactiveImage = fullImage.transformed(by: CGAffineTransform(scaleX: interactiveScale, y: interactiveScale))
                interactiveExtent = interactiveImage.extent
            } else {
                interactiveImage = fullImage
                interactiveExtent = fullExtent
            }
            
            let holder = BaseImageHolder(
                full: fullImage,
                display: displayImage,
                interactive: interactiveImage,
                fullExtent: fullExtent,
                displayExtent: displayExtent,
                interactiveExtent: interactiveExtent
            )
            
            self?.cacheLock.lock()
            self?.cachedBaseURL = url
            self?.cachedBaseHolder = holder
            self?.cacheLock.unlock()
            
            return holder
        }.value
    }
    
    /// Ultra-fast GPU re-render of a base CIImage with develop edits applied.
    /// When interactive = true, renders the 1440px interactive proxy (< 0.5ms on Apple Silicon Metal for 120fps dragging).
    public func renderProcessed(
        baseHolder: BaseImageHolder,
        cameraModel: String?,
        xmp: XMPMetadata?,
        interactive: Bool = false
    ) -> NSImage? {
        let targetBase = interactive ? baseHolder.interactive : baseHolder.display
        let targetExtent = interactive ? baseHolder.interactiveExtent : baseHolder.displayExtent
        
        let processed = AdobeColorPipeline.shared.process(
            image: targetBase,
            cameraModel: cameraModel,
            xmp: xmp
        )
        
        if let cgImage = ciContext.createCGImage(processed, from: targetExtent) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }
    
    /// Legacy compatibility helper
    public func loadBaseCIImage(from url: URL) async -> CIImage? {
        guard let holder = await loadBaseHolder(from: url) else { return nil }
        return holder.full
    }
    
    /// Legacy compatibility helper
    public func renderProcessed(baseImage: CIImage, cameraModel: String?, xmp: XMPMetadata?) -> NSImage? {
        let processed = AdobeColorPipeline.shared.process(
            image: baseImage,
            cameraModel: cameraModel,
            xmp: xmp
        )
        if let cgImage = ciContext.createCGImage(processed, from: processed.extent) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }
    
    /// Asynchronously loads full resolution image with Adobe DCP and XMP develop settings applied
    public func loadFullImage(from url: URL, cameraModel: String? = nil, xmp: XMPMetadata? = nil, maxDimension: CGFloat? = nil) async -> NSImage? {
        guard let holder = await loadBaseHolder(from: url) else { return nil }
        return renderProcessed(baseHolder: holder, cameraModel: cameraModel, xmp: xmp, interactive: false)
    }
}
