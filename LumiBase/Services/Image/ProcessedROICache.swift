import Foundation
import AppKit
import CoreImage
import CryptoKit
import ImageIO

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
    let image: NSImage
    let identity: ProcessedROIIdentity
    let costBytes: Int
}

struct ProcessedROIBitmapCache {
    private struct Stored { let entry: ProcessedROIEntry; let sequence: UInt64 }
    let capacityBytes: Int
    let maximumEntries: Int
    private var entries: [ProcessedROIIdentity: Stored] = [:]
    private var sequence: UInt64 = 0
    private(set) var accountedBytes = 0
    init(capacityBytes: Int = 128 * 1024 * 1024, maximumEntries: Int = 3) {
        self.capacityBytes = max(0, capacityBytes); self.maximumEntries = max(0, maximumEntries)
    }
    var count: Int { entries.count }
    mutating func matching(_ predicate: (ProcessedROIIdentity) -> Bool) -> ProcessedROIEntry? {
        guard let key = entries.values.filter({ predicate($0.entry.identity) })
            .max(by: { $0.sequence < $1.sequence })?.entry.identity,
              let stored = entries[key] else { return nil }
        sequence &+= 1; entries[key] = Stored(entry: stored.entry, sequence: sequence)
        return stored.entry
    }
    mutating func value(for identity: ProcessedROIIdentity) -> ProcessedROIEntry? {
        guard let stored = entries[identity] else { return nil }
        sequence &+= 1; entries[identity] = Stored(entry: stored.entry, sequence: sequence)
        return stored.entry
    }
    mutating func insert(_ entry: ProcessedROIEntry) {
        guard entry.costBytes > 0, entry.costBytes <= capacityBytes, maximumEntries > 0 else { return }
        remove(entry.identity)
        while accountedBytes + entry.costBytes > capacityBytes || entries.count >= maximumEntries {
            guard let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key else { break }
            remove(oldest)
        }
        sequence &+= 1; entries[entry.identity] = Stored(entry: entry, sequence: sequence)
        accountedBytes += entry.costBytes
    }
    mutating func removeAll() { entries.removeAll(); accountedBytes = 0 }
    private mutating func remove(_ key: ProcessedROIIdentity) {
        if let old = entries.removeValue(forKey: key) { accountedBytes -= old.entry.costBytes }
    }
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
        let attrs = (try? FileManager.default.attributesOfItem(atPath: asset.fileURL.path)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? asset.dateModified.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? asset.fileSize
        let resourceID = (try? asset.fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
            .map { String(describing: $0) } ?? "unavailable"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let settingsData = (try? encoder.encode(xmp)) ?? Data("encoding-failed".utf8)
        let settings = SHA256.hash(data: settingsData).map { String(format: "%02x", $0) }.joined()
        let versionMaterial = "\(asset.fileURL.standardizedFileURL.path)|\(resourceID)|\(size)|\(modified.bitPattern)"
        let version = SHA256.hash(data: Data(versionMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
        let identity = ProcessedROIIdentity(assetID: asset.id, fileVersion: version, developSettings: settings,
            cameraModel: cameraModel ?? "", fullExtent: extent, sourceRect: sourceRect,
            normalizedCenter: center, viewport: viewport, backingScale: backing, orientation: orientation)
        return ProcessedROIRequest(asset: asset, xmp: xmp, cameraModel: cameraModel, identity: identity)
    }

    static func fileVersion(for asset: PhotoAsset) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: asset.fileURL.path)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? asset.dateModified.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? asset.fileSize
        let resourceID = (try? asset.fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
            .map { String(describing: $0) } ?? "unavailable"
        let material = "\(asset.fileURL.standardizedFileURL.path)|\(resourceID)|\(size)|\(modified.bitPattern)"
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
    private var cache = ProcessedROIBitmapCache()
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
    func cached(_ request: ProcessedROIRequest) -> ProcessedROIEntry? { cache.value(for: request.identity) }
    func cachedMatch(assetID: String, fileVersion: String, developSettings: String, cameraModel: String,
                     center: CGPoint, viewport: CGSize, backing: CGFloat, orientation: Int) -> ProcessedROIEntry? {
        cache.matching { key in
            key.assetID == assetID && key.fileVersion == fileVersion && key.developSettings == developSettings &&
            key.cameraModel == cameraModel && key.normalizedCenter == center && key.viewport == viewport &&
            key.backingScale == backing && key.orientation == orientation &&
            key.sourceRect == InspectionROI.sourceRect(extent: key.fullExtent, center: center, viewport: viewport, backing: backing)
        }
    }
    func foregroundStarted(owner: String) { foregroundOwner = owner; scheduler.foregroundStarted(); worker?.cancel(); requests.removeAll(); pump() }
    func foregroundFinished(owner: String) {
        guard foregroundOwner == owner else { return }
        foregroundOwner = nil; scheduler.foregroundFinished(); pump()
    }
    func insertForeground(_ entry: ProcessedROIEntry, owner: String) {
        guard foregroundOwner == owner, !scheduler.isSuspended else { return }
        cache.insert(entry); foregroundOwner = nil; scheduler.foregroundFinished(); pump()
    }
    func prioritize(_ jobs: [ProcessedROIRequest]) {
        worker?.cancel()
        let uncached = jobs.filter { cache.value(for: $0.identity) == nil }
        requests = Dictionary(uncached.map { ($0.identity, $0) }, uniquingKeysWith: { _, last in last })
        scheduler.prioritize(uncached.map(\.identity)); pump()
    }
    func memoryPressure() { scheduler.setMemorySuspended(true); worker?.cancel(); cache.removeAll(); requests.removeAll(); pump() }
    func memoryRestored() { scheduler.setMemorySuspended(false); pump() }
    var cachedEntryCount: Int { cache.count }
    var accountedBitmapBytes: Int { cache.accountedBytes }
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
        if mayPublish, let entry, entry.identity == job.identity { cache.insert(entry) }
        if !scheduler.isPending(job.identity) { requests.removeValue(forKey: job.identity) }
        pump()
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
        let entry = ProcessedROIEntry(image: image, identity: request.identity, costBytes: cg.bytesPerRow * cg.height)
        return entry
    }
}
