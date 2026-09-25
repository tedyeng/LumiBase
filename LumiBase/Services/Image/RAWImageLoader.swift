import Foundation
import AppKit
import CoreImage
import ImageIO
import Dispatch

/// Serializes synchronous ImageIO/CIRAWFilter decodes across foreground and speculative loaders.
final class RAWDecodeConcurrencyGate: @unchecked Sendable {
    static let shared = RAWDecodeConcurrencyGate()
    private let semaphore = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var active = 0
    private(set) var maximumConcurrent = 0

    func withPermit<T>(_ operation: () -> T) -> T {
        semaphore.wait()
        lock.lock()
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        lock.unlock()
        defer {
            lock.lock(); active -= 1; lock.unlock()
            semaphore.signal()
        }
        return operation()
    }
}

struct RAWDecodeSettings: Equatable {
    let temperature: Int?
    let tint: Int?
    init(_ xmp: XMPMetadata?) {
        temperature = xmp?.temperature
        tint = xmp?.tint
    }
}

public struct BaseImageHolder: @unchecked Sendable {
    public let full: CIImage
    public let display: CIImage
    public let interactive: CIImage
    public let fullExtent: CGRect
    public let displayExtent: CGRect
    public let interactiveExtent: CGRect
    public let baseTemperature: Float?
    public let baseTint: Float?
    public let baseExposure: Float?
    public let isRaw: Bool
    /// False for embedded previews and unverified ImageIO RAW fallbacks.
    public var supportsNativeInspection: Bool = true
    public var highlightsSource: HighlightsSourceRecipe? = nil
}

/// High-resolution RAW and raster image loader for Loupe view
public final class RAWImageLoader: @unchecked Sendable {
    public static let shared = RAWImageLoader()
    
    private let ciContext: CIContext
    
    init() {
        // High performance Metal-backed CoreImage Context
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
    }
    
    // In-memory cache for the currently active base CIImage holder
    private var cachedSettings = RAWDecodeSettings(nil)
    private var cachedBaseURL: URL?
    private var cachedBaseHolder: BaseImageHolder?
    private let cacheLock = NSLock()
    
    private func getCached(for url: URL, settings: RAWDecodeSettings) -> BaseImageHolder? {
        cacheLock.lock()
        let holder = (cachedBaseURL == url && cachedSettings == settings) ? cachedBaseHolder : nil
        cacheLock.unlock()
        if let source = holder?.highlightsSource, !source.isCurrent { return nil }
        return holder
    }
    
    private func setCached(url: URL, holder: BaseImageHolder, settings: RAWDecodeSettings) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedSettings = settings
        cachedBaseURL = url
        cachedBaseHolder = holder
    }
    
    public func clearCache() {
        NativeHighlightsService.shared.clear()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedBaseURL = nil
        cachedBaseHolder = nil
    }
    
    /// Asynchronously decodes and retrieves the base neutral CIImage holder (with full, display, and interactive proxies)
    public func loadBaseHolder(from url: URL, xmp: XMPMetadata? = nil, useSharedCache: Bool = true,
                               priority: TaskPriority = .userInitiated) async -> BaseImageHolder? {
        let settings = RAWDecodeSettings(xmp)
        if useSharedCache, let cached = getCached(for: url, settings: settings) { return cached }
        guard !Task.isCancelled else { return nil }
        
        let work = Task.detached(priority: priority) { [weak self] () -> BaseImageHolder? in
            return RAWDecodeConcurrencyGate.shared.withPermit {
            guard !Task.isCancelled else { return nil }
            let pathExtension = url.pathExtension.lowercased()
            let isRaw = SupportedFileType(rawValue: pathExtension)?.isRaw ?? false
            
            var baseCIImage: CIImage?
            var supportsNativeInspection = !isRaw
            var baseTemp: Float? = nil
            var baseTint: Float? = nil
            var baseExp: Float? = nil
            
            // 1. Try CIRAWFilter for Apple RAW engine
            if isRaw {
                if let rawFilter = CIRAWFilter(imageURL: url) {
                    // Pass native RAW decode parameters
                    let defaultTemp = rawFilter.neutralTemperature
                    let defaultTint = rawFilter.neutralTint
                    
                    rawFilter.exposure = 0.0
                    baseExp = 0.0
                    
                    if let temp = xmp?.temperature, temp > 0 {
                        rawFilter.neutralTemperature = Float(temp)
                        baseTemp = Float(temp)
                    } else {
                        baseTemp = defaultTemp
                    }
                    if let tint = xmp?.tint {
                        // Adobe Camera Raw Planckian locus compensation:
                        // When Kelvin changes relative to native shot temp, Apple RAW drifts in tint without Planckian offset
                        let tempDelta = Double((baseTemp ?? defaultTemp) - defaultTemp)
                        let tintOffset = Float(tempDelta * 0.012)
                        rawFilter.neutralTint = Float(tint) + tintOffset
                        baseTint = Float(tint)
                    } else {
                        baseTint = defaultTint
                    }
                    
                    // Calibrated CIRAWFilter baseline settings to match Adobe Camera Raw 1:1
                    rawFilter.baselineExposure = 0.30
                    rawFilter.shadowBias = 0.0
                    rawFilter.boostShadowAmount = 0.0
                    rawFilter.boostAmount = 1.0
                    if #available(macOS 26.0, *) {
                        rawFilter.isHighlightRecoveryEnabled = true
                    }
                    
                    baseCIImage = rawFilter.outputImage
                    supportsNativeInspection = baseCIImage != nil
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
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
                        baseCIImage = CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation)
                    } else {
                        // Fallback to high-res embedded preview
                        let thumbOptions: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 4096
                        ]
                        if let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                            baseCIImage = CIImage(cgImage: thumbCG)
                            supportsNativeInspection = false
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
                interactiveExtent: interactiveExtent,
                baseTemperature: baseTemp,
                baseTint: baseTint,
                baseExposure: baseExp,
                isRaw: isRaw,
                supportsNativeInspection: supportsNativeInspection,
                highlightsSource: supportsNativeInspection && isRaw ? HighlightsSourceRecipe(url: url) : nil
            )
            
            guard !Task.isCancelled else { return nil }
            if useSharedCache { self?.setCached(url: url, holder: holder, settings: settings) }
            
            return holder
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    
    /// Ultra-fast GPU re-render of a base CIImage with develop edits applied.
    /// When interactive = true, renders the 1440px interactive proxy (< 0.5ms on Apple Silicon Metal for 120fps dragging).
    public func renderProcessed(
        baseHolder: BaseImageHolder,
        cameraModel: String?,
        xmp: XMPMetadata?,
        interactive: Bool = false,
        fullResolution: Bool = false,
        sourceRect: CGRect? = nil
    ) -> NSImage? {
        guard !fullResolution || baseHolder.supportsNativeInspection else { return nil }
        let targetBase = fullResolution ? baseHolder.full : (interactive ? baseHolder.interactive : baseHolder.display)
        let targetExtent = fullResolution ? baseHolder.fullExtent : (interactive ? baseHolder.interactiveExtent : baseHolder.displayExtent)
        
        let processed: CIImage
        if NativeHighlightsService.applies(holder: baseHolder, xmp: xmp),
           let source = baseHolder.highlightsSource, let xmp {
            guard let native = NativeHighlightsService.shared.image(source: source, xmp: xmp, cameraModel: cameraModel) else { return nil }
            let scale = targetExtent.width / baseHolder.fullExtent.width
            processed = fullResolution ? native : native.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            processed = AdobeColorPipeline.shared.process(image: targetBase, cameraModel: cameraModel, xmp: xmp, baseHolder: baseHolder)
        }
        
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let outputExtent: CGRect
        if let sourceRect {
            outputExtent = sourceRect.intersection(targetExtent)
            guard !outputExtent.isEmpty else { return nil }
        } else {
            let pExtent = processed.extent
            outputExtent = (pExtent.isInfinite || pExtent.isEmpty) ? targetExtent : pExtent
        }
        let renderContext = NativeHighlightsService.applies(holder: baseHolder, xmp: xmp) ? NativeHighlightsService.shared.renderContext : ciContext
        if let cgImage = renderContext.createCGImage(processed, from: outputExtent, format: .RGBA8, colorSpace: srgb, deferred: false) {
            guard !Task.isCancelled, baseHolder.highlightsSource?.isCurrent != false else { return nil }
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
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let cgImage = ciContext.createCGImage(processed, from: processed.extent, format: .RGBA8, colorSpace: srgb) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }
    
    /// Asynchronously loads full resolution image with Adobe DCP and XMP develop settings applied
    public func loadFullImage(from url: URL, cameraModel: String? = nil, xmp: XMPMetadata? = nil, maxDimension: CGFloat? = nil) async -> NSImage? {
        guard let holder = await loadBaseHolder(from: url, xmp: xmp) else { return nil }
        return await Task.detached { self.renderProcessed(baseHolder: holder, cameraModel: cameraModel, xmp: xmp, interactive: false) }.value
    }
}
