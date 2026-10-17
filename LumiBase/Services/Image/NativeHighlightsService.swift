import Foundation
import CoreImage

/// Immutable ownership of the source used to create a holder. No image/RAW decoder is retained.
public struct HighlightsSourceRecipe: Sendable, Equatable {
    public let url: URL
    public let version: String

    public init?(url: URL) {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber,
              let date = values[.modificationDate] as? Date else { return nil }
        self.url = url.standardizedFileURL
        version = "\(size):\(date.timeIntervalSince1970.bitPattern):\(values[.systemFileNumber] ?? "-")"
    }
    var isCurrent: Bool { HighlightsSourceRecipe(url: url) == self }
}

/// All native, Fit and export consumers share this one-entry, settings-complete cache.
/// Only immutable CI graphs/global field cross the lock. Heavy preparation is off-main,
/// serial, and never holds the short state lock used by folder/cache invalidation.
final class NativeHighlightsService: @unchecked Sendable {
    static let shared = NativeHighlightsService()
    public static var isEnabled: Bool = (UserDefaults.standard.object(forKey: "isNativeHighlightsEnabled") as? Bool) ?? true
    enum NeutralDomain: Equatable { case preview, nativeRAWExport }
    struct Key: Equatable {
        let source: HighlightsSourceRecipe
        let settings: String
        let cameraModel: String?
        let isFullRes: Bool
        let neutralDomain: NeutralDomain
        init(source: HighlightsSourceRecipe, xmp: XMPMetadata, cameraModel: String?, isFullRes: Bool = true, neutralDomain: NeutralDomain = .preview) {
            self.source = source
            settings = xmp.thumbnailDevelopCacheIdentity
            self.cameraModel = cameraModel
            self.isFullRes = isFullRes
            self.neutralDomain = neutralDomain
        }
    }
    struct Statistics {
        let preparations: Int
        let hits: Int
        let entries: Int
        let preparationMilliseconds: Double
        let endpointDecodes: Int
    }
    private struct Entry {
        let key: Key
        let field: LightcraftHighlightsKernel.Field
        let baseHolder: BaseImageHolder
        let cameraModel: String?
        
        func image(xmp: XMPMetadata, strength: Float, hlFactor: Float) -> CIImage? {
            guard let recovered = LightcraftHighlightsKernel.apply(field: field, hlFactor: hlFactor) else { return nil }
            return AdobeColorPipeline.shared.process(image: recovered, cameraModel: cameraModel, xmp: xmp, baseHolder: baseHolder)
        }
    }
    private let stateLock = NSLock()
    private let preparationLock = NSLock()
    private var generation: UInt64 = 0
    private var entry: Entry?
    private var preparations = 0
    private var hits = 0
    private var preparationMilliseconds = 0.0
    private var endpointDecodes = 0
    private struct EndpointKey: Equatable {
        let source: HighlightsSourceRecipe
        let wb: RAWDecodeSettings
        let rawExposure: Float
        let metadataExposure: Float
        let isFullRes: Bool
    }
    // At most one source/WB pair and four immutable endpoint graphs (EV0/EV-2 full/draft).
    // Never cache reduced/quantized endpoint pixels.
    private var endpoints: [(EndpointKey, BaseImageHolder)] = []
    let renderContext = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])

    static func strength(_ highlights: Int) -> Float { Float(-max(-100, min(0, highlights))) / 80 }
    /// Explicit per-photo metadata wins. Legacy sidecars retain the former
    /// app-level preference until a choice is saved for that photo.
    static func isAdvancedEnabled(for xmp: XMPMetadata?) -> Bool {
        xmp?.advancedRAWHighlightRecovery ?? isEnabled
    }
    static func applies(holder: BaseImageHolder, xmp: XMPMetadata?) -> Bool {
        isAdvancedEnabled(for: xmp) && holder.isRaw && holder.supportsNativeInspection && holder.highlightsSource != nil && (xmp?.highlights2012 ?? 0) < 0
    }
    func clear() {
        stateLock.lock()
        generation &+= 1
        entry = nil
        endpoints.removeAll()
        stateLock.unlock()
    }
    var statistics: Statistics {
        stateLock.lock(); defer { stateLock.unlock() }
        return Statistics(preparations: preparations, hits: hits, entries: entry == nil ? 0 : 1,
                          preparationMilliseconds: preparationMilliseconds, endpointDecodes: endpointDecodes)
    }


    /// A main-thread caller must arrange an asynchronous render rather than block the UI.
    func image(source: HighlightsSourceRecipe, xmp: XMPMetadata, cameraModel: String?, isFullRes: Bool = true, neutralDomain: NeutralDomain = .preview, isCurrent: () -> Bool = { true }) -> CIImage? {
        guard isCurrent(), !Thread.isMainThread, !Task.isCancelled, source.isCurrent else { return nil }
        var anchorSettings = xmp
        anchorSettings.highlights2012 = -80
        let key = Key(source: source, xmp: anchorSettings, cameraModel: cameraModel, isFullRes: isFullRes, neutralDomain: neutralDomain)
        let amount = Self.strength(xmp.highlights2012 ?? 0)
        let hlFactor = Float(xmp.highlights2012 ?? 0) / 100.0
        preparationLock.lock(); defer { preparationLock.unlock() }
        guard isCurrent(), !Task.isCancelled, source.isCurrent else { return nil }
        stateLock.lock()
        if let ready = entry, ready.key == key {
            hits += 1
            stateLock.unlock()
            return ready.image(xmp: xmp, strength: amount, hlFactor: hlFactor)
        }
        // Evict the previous source/settings graph before preparing a replacement;
        // completed UI bitmaps have their own existing ROI/Fit ownership.
        entry = nil
        let ticket = generation
        stateLock.unlock()
        let start = ProcessInfo.processInfo.systemUptime
        let prepared: Entry? = autoreleasepool { () -> Entry? in
            // Reconstruct unclipped linear highlights by blending baseline EV0 and underexposed RAW EV-2.
            guard let baselineHolder = endpoint(source: source, xmp: xmp, rawExposure: 0, metadataExposure: 0, isFullRes: isFullRes, generation: ticket),
                  let targetHolder = endpoint(source: source, xmp: xmp, rawExposure: -2, metadataExposure: 0, isFullRes: isFullRes, generation: ticket),
                  baselineHolder.fullExtent.width * baselineHolder.fullExtent.height <= 128_000_000,
                  isCurrent(), !Task.isCancelled else { return nil }
            guard let field = LightcraftHighlightsKernel.prepare(ev0: baselineHolder.full, ev2: targetHolder.full),
                  isCurrent(), !Task.isCancelled else { return nil }
            return Entry(key: key, field: field, baseHolder: baselineHolder, cameraModel: cameraModel)
        }
        guard let prepared, isCurrent(), !Task.isCancelled, source.isCurrent else { return nil }
        stateLock.lock(); defer { stateLock.unlock() }
        guard ticket == generation else { return nil }
        preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        preparations += 1
        entry = prepared
        return prepared.image(xmp: xmp, strength: amount, hlFactor: hlFactor)
    }

    private static let strengthKernel = CIColorKernel(source: """
        kernel vec4 highlightsStrength(__sample zero, __sample anchor, float amount) {
            vec3 displayZero = clamp(zero.rgb, 0.0, 1.0);
            vec3 displayAnchor = clamp(anchor.rgb, 0.0, 1.0);
            return vec4(clamp(displayZero + amount * (displayAnchor - displayZero), 0.0, 1.0), anchor.a);
        }
        """)

    /// Native RAW attenuation is independent of Boost. Both endpoint holders describe
    /// the baseline EV0 so the legacy XMP EV adjustment does not undo the dark RAW -2.
    private func endpoint(source: HighlightsSourceRecipe, xmp: XMPMetadata,
                          rawExposure: Float, metadataExposure: Float, isFullRes: Bool, generation ticket: UInt64) -> BaseImageHolder? {
        let key = EndpointKey(source: source, wb: RAWDecodeSettings(xmp), rawExposure: rawExposure, metadataExposure: metadataExposure, isFullRes: isFullRes)
        stateLock.lock()
        guard ticket == generation else { stateLock.unlock(); return nil }
        if let hit = endpoints.first(where: { $0.0 == key }) {
            stateLock.unlock()
            return hit.1
        }
        if let prior = endpoints.first, prior.0.source != source || prior.0.wb != key.wb { endpoints.removeAll() }
        endpointDecodes += 1
        stateLock.unlock()
        guard let raw = CIRAWFilter(imageURL: source.url) else { return nil }
        let defaultTemp = raw.neutralTemperature
        let defaultTint = raw.neutralTint
        let temperature = xmp.temperature.flatMap { $0 > 0 ? Float($0) : nil } ?? defaultTemp
        let tint = xmp.tint.map(Float.init) ?? defaultTint
        if let temp = xmp.temperature, temp > 0 { raw.neutralTemperature = Float(temp) }
        if xmp.tint != nil { raw.neutralTint = tint + Float(Double(temperature - defaultTemp) * 0.012) }
        raw.exposure = rawExposure
        // Both highlight endpoints retain the same native per-file BaselineExposure.
        raw.shadowBias = 0
        raw.boostShadowAmount = 0
        raw.boostAmount = 1
        if !isFullRes {
            raw.isDraftModeEnabled = true
        }
        if #available(macOS 26.0, *) { raw.isHighlightRecoveryEnabled = true }
        guard let out = raw.outputImage else { return nil }
        let holder = BaseImageHolder(full: out, display: out, interactive: out,
            fullExtent: out.extent, displayExtent: out.extent, interactiveExtent: out.extent,
            baseTemperature: temperature, baseTint: tint, baseExposure: metadataExposure, isRaw: true)
        guard !Task.isCancelled, source.isCurrent else { return nil }
        stateLock.lock(); defer { stateLock.unlock() }
        guard ticket == generation else { return nil }
        if endpoints.count >= 4 { endpoints.removeFirst() }
        endpoints.append((key, holder))
        return holder
    }
}
