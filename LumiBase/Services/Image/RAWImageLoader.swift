import Foundation
import AppKit
import CoreImage
import ImageIO

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
    
    /// Asynchronously loads full resolution or display resolution image with Adobe DCP and XMP develop settings applied
    public func loadFullImage(from url: URL, cameraModel: String? = nil, xmp: XMPMetadata? = nil, maxDimension: CGFloat? = nil) async -> NSImage? {
        return await Task.detached(priority: .userInitiated) { [ciContext] () -> NSImage? in
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
            
            guard let rawImage = baseCIImage else {
                return nil
            }
            
            // 3. Process through Adobe DCP Color & Tone Pipeline (1:1 Lightroom match)
            let processedImage = AdobeColorPipeline.shared.process(
                image: rawImage,
                cameraModel: cameraModel,
                xmp: xmp
            )
            
            // 4. Render to CGImage using Metal GPU CIContext
            if let cgImage = ciContext.createCGImage(processedImage, from: processedImage.extent) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            
            return nil
        }.value
    }
}
