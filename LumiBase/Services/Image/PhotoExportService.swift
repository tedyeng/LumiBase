import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Progress information during batch photo export
public struct ExportProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentFilename: String
    public let outputURL: URL?
    
    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

/// Errors that can occur during export
public enum ExportError: LocalizedError, Sendable {
    case failedToDecodeSource(URL)
    case failedToRenderImage(String)
    case failedToCreateDestination(URL)
    case failedToFinalizeDestination(URL)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .failedToDecodeSource(let url):
            return "Failed to decode photo at \(url.lastPathComponent)."
        case .failedToRenderImage(let reason):
            return "Image rendering failed: \(reason)."
        case .failedToCreateDestination(let url):
            return "Could not create destination JPEG at \(url.path)."
        case .failedToFinalizeDestination(let url):
            return "Could not write JPEG data to \(url.lastPathComponent)."
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

/// High-fidelity RAW + XMP to JPEG export service matching Adobe Lightroom Classic output
public final class PhotoExportService: @unchecked Sendable {
    public static let shared = PhotoExportService()
    
    private let ciContext: CIContext
    private let sRGBColorSpace: CGColorSpace
    
    private init() {
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
        self.sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
    
    /// Exports a single photo asset with XMP develop settings to a high-quality JPEG
    /// - Parameters:
    ///   - asset: The source photo asset
    ///   - destinationURL: Target file URL for the .jpg output
    ///   - quality: JPEG quality from 0.0 to 1.0 (default 0.95 = 95% quality)
    /// - Returns: The URL of the saved JPEG
    @discardableResult
    public func exportPhoto(
        asset: PhotoAsset,
        to destinationURL: URL,
        quality: Float = 0.95
    ) throws -> URL {
        // 1. Decode full resolution image
        let sourceRecipe = asset.isRaw ? HighlightsSourceRecipe(url: asset.fileURL) : nil
        var baseCI: CIImage?
        var exportBaseHolder: BaseImageHolder? = nil
        if asset.isRaw {
            if let rawFilter = CIRAWFilter(imageURL: asset.fileURL) {
                let defaultTemp = rawFilter.neutralTemperature
                let defaultTint = rawFilter.neutralTint
                let ev = Float(asset.xmp.exposure2012 ?? 0.0)
                // Bake the RAW exposure into this render endpoint. The holder's
                // baseExposure must describe the pixels it owns so the downstream
                // EV-delta stage does not apply the same adjustment twice.
                rawFilter.exposure = ev
                let decodedTemp: Float
                if let temp = asset.xmp.temperature, temp > 0 {
                    rawFilter.neutralTemperature = Float(temp)
                    decodedTemp = Float(temp)
                } else {
                    decodedTemp = defaultTemp
                }
                let decodedTint: Float
                if let tint = asset.xmp.tint {
                    let tempDelta = Double(decodedTemp - defaultTemp)
                    let tintOffset = Float(tempDelta * 0.012)
                    rawFilter.neutralTint = Float(tint) + tintOffset
                    decodedTint = Float(tint)
                } else {
                    decodedTint = defaultTint
                }
                rawFilter.baselineExposure = 0.30
                rawFilter.shadowBias = 0.0
                rawFilter.boostShadowAmount = 0.0
                rawFilter.boostAmount = 1.0
                if #available(macOS 26.0, *) {
                    rawFilter.isHighlightRecoveryEnabled = true
                }
                if let out = rawFilter.outputImage {
                    baseCI = out
                    exportBaseHolder = BaseImageHolder(
                        full: out,
                        display: out,
                        interactive: out,
                        fullExtent: out.extent,
                        displayExtent: out.extent,
                        interactiveExtent: out.extent,
                        baseTemperature: decodedTemp,
                        baseTint: decodedTint,
                        baseExposure: ev,
                        isRaw: true
                    )
                }
            }
        }
        
        if baseCI == nil {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: true
            ]
            if let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
               let fullCG = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                var img = CIImage(cgImage: fullCG)
                // If raster image has non-default orientation, apply orientation transform
                if let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                   let rawOrientation = sourceProperties[kCGImagePropertyOrientation as String] as? UInt32,
                   let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) {
                    img = img.oriented(orientation)
                }
                baseCI = img
            }
        }
        
        guard let sourceCI = baseCI else {
            throw ExportError.failedToDecodeSource(asset.fileURL)
        }
        
        // 2. Apply Adobe PV2012 Color Pipeline (Exposure, WB, Highlights, Shadows, Contrast, Saturation, Clarity)
        let processedCI: CIImage
        if NativeHighlightsService.isEnabled, exportBaseHolder != nil, (asset.xmp.highlights2012 ?? 0) < 0 {
            guard let recipe = sourceRecipe else {
                throw ExportError.failedToRenderImage("Highlights require a current source and off-main render; preparation was cancelled or failed")
            }
            let nativeImage: CIImage?
            if Thread.isMainThread {
                let sema = DispatchSemaphore(value: 0)
                var result: CIImage?
                DispatchQueue.global(qos: .userInitiated).async {
                    result = NativeHighlightsService.shared.image(source: recipe, xmp: asset.xmp, cameraModel: asset.cameraMetadata.model, neutralDomain: .nativeRAWExport)
                    sema.signal()
                }
                sema.wait()
                nativeImage = result
            } else {
                nativeImage = NativeHighlightsService.shared.image(source: recipe, xmp: asset.xmp, cameraModel: asset.cameraMetadata.model, neutralDomain: .nativeRAWExport)
            }
            guard let native = nativeImage else {
                throw ExportError.failedToRenderImage("Highlights require a current source and off-main render; preparation was cancelled or failed")
            }
            processedCI = native
        } else {
            processedCI = AdobeColorPipeline.shared.process(image: sourceCI, cameraModel: asset.cameraMetadata.model, xmp: asset.xmp, baseHolder: exportBaseHolder)
        }
        
        // Determine valid non-infinite render extent
        let renderExtent = processedCI.extent.isInfinite ? sourceCI.extent : processedCI.extent
        guard renderExtent.width > 0 && renderExtent.height > 0 else {
            throw ExportError.failedToRenderImage("Render extent is invalid")
        }
        
        // 3. Render to high-fidelity CGImage in sRGB color space
        guard !Task.isCancelled else { throw ExportError.cancelled }
        let renderContext = NativeHighlightsService.isEnabled && exportBaseHolder != nil && (asset.xmp.highlights2012 ?? 0) < 0 ? NativeHighlightsService.shared.renderContext : ciContext
        guard let cgImage = renderContext.createCGImage(
            processedCI,
            from: renderExtent,
            format: .RGBA8,
            colorSpace: sRGBColorSpace
        ) else {
            throw ExportError.failedToRenderImage("CoreImage Metal rendering failed")
        }
        
        // 4. Create destination JPEG
        guard !Task.isCancelled else { throw ExportError.cancelled }
        guard sourceRecipe?.isCurrent != false else { throw ExportError.failedToDecodeSource(asset.fileURL) }
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.failedToCreateDestination(destinationURL)
        }
        
        // 5. Build destination metadata dictionary preserving original camera EXIF/TIFF/GPS
        var destProperties: [CFString: Any] = [:]
        
        // JPEG compression quality: 0.0 to 1.0 (default 0.95 = 95% high quality)
        destProperties[kCGImageDestinationLossyCompressionQuality] = max(0.0, min(1.0, quality))
        
        // Since CoreImage/CIRAWFilter renders the pixels directly into physical upright orientation,
        // the destination JPEG image orientation must be set to 1 (Normal / Upright) so that
        // photo viewers do not rotate the already-upright image a second time.
        destProperties[kCGImagePropertyOrientation] = 1
        
        // Extract metadata from source RAW file
        if let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if var exif = sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
                exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
                destProperties[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = sourceProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                destProperties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if let gps = sourceProperties[kCGImagePropertyGPSDictionary] {
                destProperties[kCGImagePropertyGPSDictionary] = gps
            }
        }
        
        CGImageDestinationAddImage(destination, cgImage, destProperties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.failedToFinalizeDestination(destinationURL)
        }
        
        return destinationURL
    }
    
    /// Exports a batch of photos to a directory with progress reporting
    /// - Parameters:
    ///   - assets: List of photo assets to export
    ///   - outputDirectory: Target directory for the exported JPEGs
    ///   - quality: JPEG quality from 0.0 to 1.0 (default 0.95)
    ///   - progressHandler: Optional progress callback invoked after each photo
    /// - Returns: List of exported file URLs
    public func exportBatch(
        assets: [PhotoAsset],
        to outputDirectory: URL,
        quality: Float = 0.95,
        progressHandler: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        var exportedURLs: [URL] = []
        let total = assets.count
        
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            
            let baseName = asset.fileURL.deletingPathExtension().lastPathComponent
            let destURL = outputDirectory.appendingPathComponent("\(baseName).jpg")
            
            let work = Task.detached { try self.exportPhoto(asset: asset, to: destURL, quality: quality) }
            let resultURL = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            exportedURLs.append(resultURL)
            
            progressHandler?(ExportProgress(
                completed: index + 1,
                total: total,
                currentFilename: asset.filename,
                outputURL: resultURL
            ))
        }
        
        return exportedURLs
    }
}
