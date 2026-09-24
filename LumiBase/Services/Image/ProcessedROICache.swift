import Foundation
import AppKit
import CoreImage
import CryptoKit
import ImageIO

/// The sole retained bitmap owner shared by preview and processed ROI producers. CGImage is
/// immutable after construction, so it can cross the lock boundary; AppKit wrappers are made
/// only by the synchronous main-thread consumer.
final class InspectionReadyFrameStore: @unchecked Sendable {
    static let shared = InspectionReadyFrameStore()
    static let budgetBytes = 128 * 1024 * 1024
    enum Key: Hashable { case preview(PreviewCacheKey); case roi(ProcessedROIIdentity) }
    enum Kind: Equatable { case fullPreview; case nativeROI }
    struct Frame: @unchecked Sendable {
        let image: CGImage
        let kind: Kind
        let fullExtent: CGRect
        let sourceRect: CGRect?
        let bytes: Int
    }
    private struct Stored { let frame: Frame; let sequence: UInt64 }
    private let lock = NSLock()
    private var entries: [Key: Stored] = [:]
    private var sequence: UInt64 = 0
    private var bytes = 0
    private init() {}

    func publish(_ frame: Frame, for key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard frame.bytes > 0, frame.bytes <= Self.budgetBytes else { return false }
        removeLocked(key)
        while bytes + frame.bytes > Self.budgetBytes,
              let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key { removeLocked(oldest) }
        sequence &+= 1; entries[key] = Stored(frame: frame, sequence: sequence); bytes += frame.bytes
        return true
    }

    func publishFullPreview(asset: PhotoAsset, xmp: XMPMetadata, image: NSImage, fullExtent: CGRect) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            InspectionTrace.event("ready.producer.render_discard_no_cgimage"); return
        }
        var identityAsset = asset; identityAsset.xmp = xmp
        let frame = Frame(image: cg, kind: .fullPreview, fullExtent: fullExtent, sourceRect: nil,
                          bytes: cg.bytesPerRow * cg.height)
        let accepted = publish(frame, for: .preview(PreviewCacheKey(asset: identityAsset,
            maxPixelSize: PreviewPreloader.previewSize, pipelineIdentity: "imageio-embedded-transformed-rgba-v1")))
        InspectionTrace.event(accepted ? "ready.producer.rendered_fit_published" : "ready.producer.rendered_fit_budget_rejected")
    }

    func preview(for key: PreviewCacheKey) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let stored = entries[.preview(key)], stored.frame.kind == .fullPreview else { return nil }
        sequence &+= 1; entries[.preview(key)] = Stored(frame: stored.frame, sequence: sequence)
        return stored.frame
    }

    func roi(assetID: String, fileVersion: String, settings: String, cameraModel: String,
             center: CGPoint, viewport: CGSize, backing: CGFloat, orientation: Int) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        let key = entries.keys.compactMap { key -> ProcessedROIIdentity? in
            guard case .roi(let identity) = key,
                  identity.assetID == assetID, identity.fileVersion == fileVersion,
                  identity.developSettings == settings, identity.cameraModel == cameraModel,
                  identity.normalizedCenter == center, identity.viewport == viewport,
                  identity.backingScale == backing,
                  identity.orientation == orientation,
                  identity.sourceRect == InspectionROI.sourceRect(extent: identity.fullExtent, center: center, viewport: viewport, backing: backing) else { return nil }
            return identity
        }.max { (entries[.roi($0)]?.sequence ?? 0) < (entries[.roi($1)]?.sequence ?? 0) }
        guard let key, let stored = entries[.roi(key)] else { return nil }
        sequence &+= 1; entries[.roi(key)] = Stored(frame: stored.frame, sequence: sequence)
        return stored.frame
    }

    func clearPreviews() { clear(where: { if case .preview = $0 { return true }; return false }) }
    func clearROIs() { clear(where: { if case .roi = $0 { return true }; return false }) }
    func clearAll() { clear(where: { _ in true }) }
    var accountedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var roiEntryCount: Int { lock.lock(); defer { lock.unlock() }; return entries.keys.reduce(0) { count, key in if case .roi = key { count + 1 } else { count } } }
    private func clear(where predicate: (Key) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        for key in entries.keys.filter(predicate) { removeLocked(key) }
    }
    private func removeLocked(_ key: Key) { if let old = entries.removeValue(forKey: key) { bytes -= old.frame.bytes } }
}

struct ProcessedROIIdentity: Hashable, Sendable {
    let assetID: String
    let fileVersion: String
    let developSettings: String
    let cameraModel: String
    let fullExtent: CGRect
    let sourceRect: CGRect
    let normalizedCenter: CGPoint
    let viewport: CGSize
    let backingScale: CGFloat
    let orientation: Int
}

struct ProcessedROIEntry: @unchecked Sendable {
    /// Immutable pixel storage is the only image object that crosses actor/lock boundaries.
    let image: CGImage
    let identity: ProcessedROIIdentity
    let costBytes: Int
}

struct ProcessedROIJob: Equatable, Sendable {
    let id: UInt64
    let generation: UInt64
    let identity: ProcessedROIIdentity
}

/// A single active speculative render. Reprioritization discards queued work and invalidates
/// publication, but the active slot remains occupied until an uninterruptible RAW/GPU call returns.
struct ProcessedROIScheduler {
    private(set) var generation: UInt64 = 0
    private(set) var running: ProcessedROIJob?
    private var pending: [ProcessedROIIdentity] = []
    private var nextID: UInt64 = 0
    private var suspended = false
    private var foregroundPending = false
    init() {}
    var runningCount: Int { running == nil ? 0 : 1 }
    var isSuspended: Bool { suspended }
    func isPending(_ identity: ProcessedROIIdentity) -> Bool { pending.contains(identity) }
    mutating func prioritize(_ identities: [ProcessedROIIdentity]) {
        generation &+= 1
        var seen = Set<ProcessedROIIdentity>()
        pending = identities.filter { seen.insert($0).inserted }
    }
    mutating func foregroundStarted() { foregroundPending = true; generation &+= 1; pending.removeAll() }
    mutating func foregroundFinished() { foregroundPending = false }
    mutating func setMemorySuspended(_ value: Bool) { suspended = value; if value { generation &+= 1; pending.removeAll() } }
    mutating func beginNext() -> ProcessedROIJob? {
        guard running == nil, !pending.isEmpty, !suspended, !foregroundPending else { return nil }
        nextID &+= 1
        let job = ProcessedROIJob(id: nextID, generation: generation, identity: pending.removeFirst())
        running = job; return job
    }
    mutating func finish(_ job: ProcessedROIJob) -> Bool {
        guard running?.id == job.id else { return false }
        running = nil
        return job.generation == generation && !suspended && !foregroundPending
    }
}

struct ProcessedROIRequest: @unchecked Sendable {
    let asset: PhotoAsset
    let xmp: XMPMetadata
    let cameraModel: String?
    let identity: ProcessedROIIdentity

    static func make(asset: PhotoAsset, xmp: XMPMetadata, cameraModel: String?, center: CGPoint,
                     viewport: CGSize, backing: CGFloat, orientation: Int, extent: CGRect,
                     sourceRect: CGRect) -> ProcessedROIRequest {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let settingsData = (try? encoder.encode(xmp)) ?? Data("encoding-failed".utf8)
        let settings = SHA256.hash(data: settingsData).map { String(format: "%02x", $0) }.joined()
        let version = fileVersion(for: asset)
        let identity = ProcessedROIIdentity(assetID: asset.id, fileVersion: version, developSettings: settings,
            cameraModel: cameraModel ?? "", fullExtent: extent, sourceRect: sourceRect,
            normalizedCenter: center, viewport: viewport, backingScale: backing, orientation: orientation)
        return ProcessedROIRequest(asset: asset, xmp: xmp, cameraModel: cameraModel, identity: identity)
    }

    static func fileVersion(for asset: PhotoAsset) -> String {
        // Use scanner-owned metadata so synchronous selection handoff never stats the file.
        let material = "\(asset.fileURL.standardizedFileURL.path)|\(asset.fileSize)|\(asset.dateModified.timeIntervalSince1970.bitPattern)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func settingsIdentity(_ xmp: XMPMetadata) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(xmp)) ?? Data("encoding-failed".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func orientedExtent(for asset: PhotoAsset) -> (CGRect, Int)? {
        guard let src = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swaps = [5, 6, 7, 8].contains(orientation)
        return (CGRect(x: 0, y: 0, width: swaps ? h : w, height: swaps ? w : h), orientation)
    }
}

/// Isolated worker: never touches the foreground loader cache or foreground render queue.
actor ProcessedROICacheService {
    static let shared = ProcessedROICacheService()
    typealias Renderer = @Sendable (ProcessedROIRequest) async -> ProcessedROIEntry?
    private var scheduler = ProcessedROIScheduler()
    private var requests: [ProcessedROIIdentity: ProcessedROIRequest] = [:]
    private var worker: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var foregroundOwner: String?
    private let renderer: Renderer

    init(renderer: Renderer? = nil) {
        if let renderer { self.renderer = renderer }
        else { self.renderer = { request in await Self.renderIsolated(request) } }
        Task { await installMemoryPressureObserver() }
    }
    func cached(_ request: ProcessedROIRequest) -> InspectionReadyFrameStore.Frame? {
        InspectionReadyFrameStore.shared.roi(assetID: request.identity.assetID, fileVersion: request.identity.fileVersion,
            settings: request.identity.developSettings, cameraModel: request.identity.cameraModel,
            center: request.identity.normalizedCenter, viewport: request.identity.viewport, backing: request.identity.backingScale,
            orientation: request.identity.orientation)
    }
    func cachedMatch(assetID: String, fileVersion: String, developSettings: String, cameraModel: String,
                     center: CGPoint, viewport: CGSize, backing: CGFloat, orientation: Int) -> InspectionReadyFrameStore.Frame? {
        InspectionReadyFrameStore.shared.roi(assetID: assetID, fileVersion: fileVersion, settings: developSettings,
            cameraModel: cameraModel, center: center, viewport: viewport, backing: backing, orientation: orientation)
    }
    func foregroundStarted(owner: String) { foregroundOwner = owner; scheduler.foregroundStarted(); worker?.cancel(); requests.removeAll(); pump() }
    func foregroundFinished(owner: String) {
        guard foregroundOwner == owner else { return }
        foregroundOwner = nil; scheduler.foregroundFinished(); pump()
    }
    func insertForeground(_ entry: ProcessedROIEntry, owner: String) {
        guard foregroundOwner == owner, !scheduler.isSuspended else { return }
        publish(entry); foregroundOwner = nil; scheduler.foregroundFinished(); pump()
    }
    func prioritize(_ jobs: [ProcessedROIRequest]) {
        worker?.cancel()
        let uncached = jobs.filter { request in
            let identity = request.identity
            return InspectionReadyFrameStore.shared.roi(assetID: identity.assetID, fileVersion: identity.fileVersion,
                settings: identity.developSettings, cameraModel: identity.cameraModel,
                center: identity.normalizedCenter, viewport: identity.viewport, backing: identity.backingScale,
                orientation: identity.orientation) == nil
        }
        requests = Dictionary(uncached.map { ($0.identity, $0) }, uniquingKeysWith: { _, last in last })
        scheduler.prioritize(uncached.map(\.identity)); pump()
    }
    func memoryPressure() { scheduler.setMemorySuspended(true); worker?.cancel(); InspectionReadyFrameStore.shared.clearAll(); requests.removeAll(); pump() }
    func memoryRestored() { scheduler.setMemorySuspended(false); pump() }
    var cachedEntryCount: Int { InspectionReadyFrameStore.shared.roiEntryCount }
    var accountedBitmapBytes: Int { InspectionReadyFrameStore.shared.accountedBytes }
    var activeSpeculativeCount: Int { scheduler.runningCount }
    var foregroundOwnerID: String? { foregroundOwner }

    private func installMemoryPressureObserver() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            let data = source.data
            Task {
                if data.contains(.warning) || data.contains(.critical) { await self?.memoryPressure() }
                else { await self?.memoryRestored() }
            }
        }
        source.resume(); memoryPressureSource = source
    }

    private func pump() {
        guard worker == nil, let job = scheduler.beginNext(), let request = requests[job.identity] else { return }
        let renderer = self.renderer
        worker = Task.detached(priority: .background) { [weak self] in
            let entry = await renderer(request)
            await self?.complete(job, entry: entry)
        }
    }
    private func complete(_ job: ProcessedROIJob, entry: ProcessedROIEntry?) {
        let mayPublish = scheduler.finish(job)
        worker = nil
        if mayPublish, let entry, entry.identity == job.identity { publish(entry) }
        else if !mayPublish { InspectionTrace.event("ready.producer.roi_discard_stale_or_cancelled") }
        else { InspectionTrace.event("ready.producer.roi_discard_render_failed") }
        if !scheduler.isPending(job.identity) { requests.removeValue(forKey: job.identity) }
        pump()
    }
    private func publish(_ entry: ProcessedROIEntry) {
        let identity = entry.identity
        let ok = InspectionReadyFrameStore.shared.publish(.init(image: entry.image, kind: .nativeROI,
            fullExtent: identity.fullExtent, sourceRect: identity.sourceRect,
            bytes: entry.image.bytesPerRow * entry.image.height), for: .roi(identity))
        InspectionTrace.event(ok ? "ready.producer.roi_published" : "ready.producer.roi_budget_rejected")
    }
    private nonisolated static func renderIsolated(_ request: ProcessedROIRequest) async -> ProcessedROIEntry? {
        guard !Task.isCancelled else { return nil }
        let loader = RAWImageLoader()
        guard let holder = await loader.loadBaseHolder(from: request.asset.fileURL, xmp: request.xmp,
                                                       useSharedCache: false, priority: .background) else { return nil }
        guard holder.fullExtent == request.identity.fullExtent,
              request.identity.fullExtent.contains(request.identity.sourceRect) else { return nil }
        guard !Task.isCancelled,
              let image = loader.renderProcessed(baseHolder: holder, cameraModel: request.cameraModel,
                  xmp: request.xmp, fullResolution: true, sourceRect: request.identity.sourceRect),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let entry = ProcessedROIEntry(image: cg, identity: request.identity, costBytes: cg.bytesPerRow * cg.height)
        return entry
    }
}
