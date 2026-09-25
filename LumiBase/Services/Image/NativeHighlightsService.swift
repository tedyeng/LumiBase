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
    enum NeutralDomain: Equatable { case preview, nativeRAWExport }
    struct Key: Equatable {
        let source: HighlightsSourceRecipe
        let settings: String
        let cameraModel: String?
        let neutralDomain: NeutralDomain
        init(source: HighlightsSourceRecipe, xmp: XMPMetadata, cameraModel: String?, neutralDomain: NeutralDomain = .preview) {
            self.source = source
            settings = xmp.thumbnailDevelopCacheIdentity
            self.cameraModel = cameraModel
            self.neutralDomain = neutralDomain
        }
    }
    struct Statistics {
        let preparations: Int
        let hits: Int
        let entries: Int
        let preparationMilliseconds: Double
    }
    private struct Entry {
        let key: Key
        let image: CIImage
    }
    private let stateLock = NSLock()
    private let preparationLock = NSLock()
    private var generation: UInt64 = 0
    private var entry: Entry?
    private var preparations = 0
    private var hits = 0
    private var preparationMilliseconds = 0.0
    let renderContext = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAf,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])

    static func strength(_ highlights: Int) -> Float { Float(-max(-100, min(0, highlights))) / 80 }
    static func applies(holder: BaseImageHolder, xmp: XMPMetadata?) -> Bool {
        holder.isRaw && holder.supportsNativeInspection && holder.highlightsSource != nil && (xmp?.highlights2012 ?? 0) < 0
    }
    func clear() {
        stateLock.lock()
        generation &+= 1
        entry = nil
        stateLock.unlock()
    }
    var statistics: Statistics {
        stateLock.lock(); defer { stateLock.unlock() }
        return Statistics(preparations: preparations, hits: hits, entries: entry == nil ? 0 : 1,
                          preparationMilliseconds: preparationMilliseconds)
    }

    /// A main-thread caller must arrange an asynchronous render rather than block the UI.
    func image(source: HighlightsSourceRecipe, xmp: XMPMetadata, cameraModel: String?, neutralDomain: NeutralDomain = .preview) -> CIImage? {
        guard !Thread.isMainThread, !Task.isCancelled, source.isCurrent else { return nil }
        let key = Key(source: source, xmp: xmp, cameraModel: cameraModel, neutralDomain: neutralDomain)
        preparationLock.lock(); defer { preparationLock.unlock() }
        guard !Task.isCancelled, source.isCurrent else { return nil }
        stateLock.lock()
        if let ready = entry, ready.key == key {
            hits += 1
            stateLock.unlock()
            return ready.image
        }
        // Evict the previous source/settings graph before preparing a replacement;
        // completed UI bitmaps have their own existing ROI/Fit ownership.
        entry = nil
        let ticket = generation
        stateLock.unlock()
        let start = ProcessInfo.processInfo.systemUptime
        let image: CIImage? = autoreleasepool {
            // Preserve the viewer's existing EV-delta domain: its base RAW is EV0,
            // with the XMP exposure applied by AdobeColorPipeline. The accepted dark
            // endpoint is an independent RAW EV-2 graph, not an EDR/linear divide.
            // Keeping both metadata EVs at zero prevents cancelling that attenuation
            // and makes the negative branch converge to the unchanged H0 preview.
            guard let baselineHolder = endpoint(source: source, xmp: xmp, rawExposure: 0, metadataExposure: 0),
                  let targetHolder = endpoint(source: source, xmp: xmp, rawExposure: -2, metadataExposure: 0),
                  baselineHolder.fullExtent.width * baselineHolder.fullExtent.height <= 128_000_000,
                  !Task.isCancelled else { return nil }
            var anchor = xmp
            anchor.highlights2012 = -80
            let baseline = AdobeColorPipeline.shared.process(image: baselineHolder.full, cameraModel: cameraModel, xmp: anchor, baseHolder: baselineHolder)
            let target = AdobeColorPipeline.shared.process(image: targetHolder.full, cameraModel: cameraModel, xmp: anchor, baseHolder: targetHolder)
            guard let field = try? AcceptedHighlightsKernel.prepare(baseline: baseline, target: target, context: renderContext),
                  !Task.isCancelled else { return nil }
            let accepted = AcceptedHighlightsKernel.apply(baseline: baseline, target: target, field: field)
            let amount = Self.strength(xmp.highlights2012 ?? 0)
            if amount == 1 { return accepted }
            var neutral = xmp
            neutral.highlights2012 = 0
            let zeroHolder: BaseImageHolder
            if neutralDomain == .nativeRAWExport, let ev = xmp.exposure2012, ev != 0 {
                guard let decoded = endpoint(source: source, xmp: neutral, rawExposure: Float(ev), metadataExposure: Float(ev)) else { return nil }
                zeroHolder = decoded
            } else { zeroHolder = baselineHolder }
            let zero = AdobeColorPipeline.shared.process(image: zeroHolder.full, cameraModel: cameraModel, xmp: neutral, baseHolder: zeroHolder)
            // Linear display-light interpolation/extrapolation, clamped to the display gamut.
            return Self.strengthKernel?.apply(extent: accepted.extent, arguments: [zero, accepted, amount])
        }
        guard let image, !Task.isCancelled, source.isCurrent else { return nil }
        stateLock.lock(); defer { stateLock.unlock() }
        guard ticket == generation else { return nil }
        preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        preparations += 1
        entry = Entry(key: key, image: image)
        return image
    }

    private static let strengthKernel = CIColorKernel(source: """
        kernel vec4 highlightsStrength(__sample zero, __sample anchor, float amount) {
            vec3 displayZero = clamp(zero.rgb, 0.0, 1.0);
            return vec4(clamp(displayZero + amount * (anchor.rgb - displayZero), 0.0, 1.0), anchor.a);
        }
        """)

    /// Native RAW attenuation is independent of Boost. Both endpoint holders describe
    /// the baseline EV0 so the legacy XMP EV adjustment does not undo the dark RAW -2.
    private func endpoint(source: HighlightsSourceRecipe, xmp: XMPMetadata,
                          rawExposure: Float, metadataExposure: Float) -> BaseImageHolder? {
        guard let raw = CIRAWFilter(imageURL: source.url) else { return nil }
        let defaultTemp = raw.neutralTemperature
        let defaultTint = raw.neutralTint
        let temperature = xmp.temperature.flatMap { $0 > 0 ? Float($0) : nil } ?? defaultTemp
        let tint = xmp.tint.map(Float.init) ?? defaultTint
        if let temp = xmp.temperature, temp > 0 { raw.neutralTemperature = Float(temp) }
        if xmp.tint != nil { raw.neutralTint = tint + Float(Double(temperature - defaultTemp) * 0.012) }
        raw.exposure = rawExposure
        raw.baselineExposure = 0.30
        raw.shadowBias = 0
        raw.boostShadowAmount = 0
        raw.boostAmount = 1
        if #available(macOS 26.0, *) { raw.isHighlightRecoveryEnabled = true }
        guard let out = raw.outputImage else { return nil }
        return BaseImageHolder(full: out, display: out, interactive: out,
            fullExtent: out.extent, displayExtent: out.extent, interactiveExtent: out.extent,
            baseTemperature: temperature, baseTint: tint, baseExposure: metadataExposure, isRaw: true)
    }
}
