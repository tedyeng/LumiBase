import Foundation

/// Opt-in read-only work counters for fixture/performance evidence; off in the app.
enum ImageWorkDiagnostics {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var counts: [String: Int] = [:]
    }
    private static let storage = Storage()
    static func start() { storage.lock.lock(); defer { storage.lock.unlock() }; storage.enabled = true; storage.counts = [:] }
    static func stop() { storage.lock.lock(); defer { storage.lock.unlock() }; storage.enabled = false }
    static func record(_ key: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        if storage.enabled { storage.counts[key, default: 0] += 1 }
    }
    static func snapshot() -> [String: Int] { storage.lock.lock(); defer { storage.lock.unlock() }; return storage.counts }
}
import AppKit
import CoreImage
import ImageIO
import Dispatch

/// Serializes synchronous ImageIO/CIRAWFilter decodes across foreground and speculative loaders.
final class RAWDecodeConcurrencyGate: @unchecked Sendable {
    static let shared = RAWDecodeConcurrencyGate()
    private let condition = NSCondition()
    private var active = 0
    private var waitingForeground = 0
    private(set) var maximumConcurrent = 0

    // Background score work yields to already queued presentation decodes.
    // An in-flight native decoder is not preemptible; cancellation is checked after it.
    func withPermit<T>(background: Bool = false, _ operation: () -> T) -> T {
        condition.lock()
        if !background { waitingForeground += 1 }
        while active != 0 || (background && waitingForeground > 0) { condition.wait() }
        if !background { waitingForeground -= 1 }
        active += 1; maximumConcurrent = max(maximumConcurrent, active)
        condition.unlock()
        defer { condition.lock(); active -= 1; condition.broadcast(); condition.unlock() }
        return operation()
    }
}

struct RAWDecodeSettings: Equatable {
    let temperature: Int?
    let tint: Int?
    let engine: RAWColorPipelineEngine
    init(_ xmp: XMPMetadata?) {
        temperature = xmp?.temperature
        tint = xmp?.tint
        engine = PerformanceSettings.currentRAWPipelineEngine
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
private final class RAWLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public final class RAWImageLoader: @unchecked Sendable {
    private static let foregroundDecode = DispatchQueue(label: "com.lumibase.raw.presentDecode", qos: .userInitiated)
    private static let backgroundDecode = DispatchQueue(label: "com.lumibase.raw.backgroundDecode", qos: .utility)
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
    
    public func cachedHolder(for url: URL) -> BaseImageHolder? {
        cacheLock.lock()
        let holder = (cachedBaseURL == url) ? cachedBaseHolder : nil
        cacheLock.unlock()
        return holder
    }

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
        ImageWorkDiagnostics.record("sourceLoad")
        let settings = RAWDecodeSettings(xmp)
        if useSharedCache, let cached = getCached(for: url, settings: settings) { return cached }
        guard !Task.isCancelled else { return nil }
        
        let cancellation = RAWLoadCancellation()
        return await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            let queue = priority == .utility || priority == .background ? Self.backgroundDecode : Self.foregroundDecode
            queue.async { [weak self] in
              let result: BaseImageHolder? = autoreleasepool {
                RAWDecodeConcurrencyGate.shared.withPermit(background: priority == .utility || priority == .background) {
                    guard !cancellation.isCancelled else { return nil }
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
                            let engine = PerformanceSettings.currentRAWPipelineEngine
                            if engine == .darkroom {
                                rawFilter.isLensCorrectionEnabled = true
                                if let tint = xmp?.tint {
                                    rawFilter.neutralTint = Float(tint)
                                    baseTint = Float(tint)
                                } else {
                                    baseTint = defaultTint
                                }
                                // Apple default shadowBias (3.0) and boostShadowAmount (0.9) preserved
                            } else {
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

                                // Preserve the decoder's per-file BaselineExposure; 0.30 is not a relative EV offset.
                                // Keep the existing shadow/boost policy unchanged.
                                rawFilter.shadowBias = 0.0
                                rawFilter.boostShadowAmount = 0.0
                                rawFilter.boostAmount = 1.0
                                if #available(macOS 26.0, *) {
                                    rawFilter.isHighlightRecoveryEnabled = true
                                }
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
            
                    guard !cancellation.isCancelled else { return nil }
                    if useSharedCache { self?.setCached(url: url, holder: holder, settings: settings) }
                    return holder
                }
              }
              continuation.resume(returning: cancellation.isCancelled ? nil : result)
            }
          }
        } onCancel: { cancellation.cancel() }
    }
    
    /// Ultra-fast GPU re-render of a base CIImage with develop edits applied.
    /// When interactive = true, renders the 1440px interactive proxy (< 0.5ms on Apple Silicon Metal for 120fps dragging).
    public func renderProcessed(
        baseHolder: BaseImageHolder,
        cameraModel: String?,
        xmp: XMPMetadata?,
        interactive: Bool = false,
        fullResolution: Bool = false,
        sourceRect: CGRect? = nil,
        background: Bool = false,
        contextOverride: CIContext? = nil,
        isCurrent: () -> Bool = { true }
    ) -> NSImage? {
        return RAWDecodeConcurrencyGate.shared.withPermit(background: background) {
            guard isCurrent(), !fullResolution || baseHolder.supportsNativeInspection else { return nil }
            ImageWorkDiagnostics.record("processedRender")
            let targetBase = fullResolution ? baseHolder.full : (interactive ? baseHolder.interactive : baseHolder.display)
            let targetExtent = fullResolution ? baseHolder.fullExtent : (interactive ? baseHolder.interactiveExtent : baseHolder.displayExtent)
        
            let processed: CIImage
            if NativeHighlightsService.applies(holder: baseHolder, xmp: xmp),
               let source = baseHolder.highlightsSource, let xmp {
                let isFull = fullResolution || (PerformanceSettings.currentHighlightPreviewQuality == .full)
                guard let native = NativeHighlightsService.shared.image(
                    source: source,
                    xmp: xmp,
                    cameraModel: cameraModel,
                    isFullRes: isFull,
                    isCurrent: isCurrent
                ) else { return nil }
                let scale = targetExtent.width / native.extent.width
                processed = (abs(scale - 1.0) < 0.001) ? native : native.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                processed = AdobeColorPipeline.shared.process(image: targetBase, cameraModel: cameraModel, xmp: xmp, baseHolder: baseHolder)
            }
        
            let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let outputExtent: CGRect
            if let sourceRect {
                outputExtent = sourceRect.intersection(targetExtent)
                guard !outputExtent.isEmpty else { return nil }
            } else if xmp?.hasCrop == true {
                let pExtent = processed.extent
                outputExtent = (pExtent.isInfinite || pExtent.isEmpty) ? targetExtent : pExtent
            } else {
                outputExtent = targetExtent
            }
            let renderContext = contextOverride ?? (NativeHighlightsService.applies(holder: baseHolder, xmp: xmp) ? NativeHighlightsService.shared.renderContext : ciContext)
            guard isCurrent() else { return nil }
            if let cgImage = renderContext.createCGImage(processed, from: outputExtent, format: .RGBA8, colorSpace: srgb, deferred: false) {
                guard isCurrent(), !Task.isCancelled, baseHolder.highlightsSource?.isCurrent != false else { return nil }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            return nil
        }
    }
    
    /// Suspend callers instead of blocking MainActor or a cooperative worker on
    /// the presentation-priority decode/render gate.
    public func renderProcessedAsync(baseHolder: BaseImageHolder, cameraModel: String?, xmp: XMPMetadata?, fullResolution: Bool = false) async -> NSImage? {
        let cancellation = RAWLoadCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.foregroundDecode.async {
                    let image: NSImage? = autoreleasepool {
                        self.renderProcessed(baseHolder: baseHolder, cameraModel: cameraModel, xmp: xmp,
                            fullResolution: fullResolution, isCurrent: { !cancellation.isCancelled })
                    }
                    continuation.resume(returning: cancellation.isCancelled ? nil : image)
                }
            }
        } onCancel: { cancellation.cancel() }
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
        return await renderProcessedAsync(baseHolder: holder, cameraModel: cameraModel, xmp: xmp)
    }
}
