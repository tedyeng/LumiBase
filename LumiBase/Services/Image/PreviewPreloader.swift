import Foundation
import AppKit
import ImageIO
import CryptoKit
import Combine
import Dispatch

public enum PreviewTravelDirection: Equatable, Sendable {
    case forward
    case backward
    case stationary
}

public enum PreviewMemoryPressureLevel { case normal, warning, critical }

public struct PreviewMemoryPressurePolicy {
    public private(set) var isSuspended = false
    public init() {}
    public mutating func receive(_ level: PreviewMemoryPressureLevel) { isSuspended = level != .normal }
}

public enum PreviewPreloadPlan {
    /// Returns neighbors by travel priority, interleaving the opposite direction by distance.
    public static func neighborIndices(count: Int, selectedIndex: Int, direction: PreviewTravelDirection, radius: Int = 3) -> [Int] {
        guard count > 0, selectedIndex >= 0, selectedIndex < count, radius > 0 else { return [] }
        let primaryStep = direction == .backward ? -1 : 1
        var result: [Int] = []
        for distance in 1...radius {
            let first = selectedIndex + primaryStep * distance
            let second = selectedIndex - primaryStep * distance
            if first >= 0, first < count { result.append(first) }
            if second >= 0, second < count { result.append(second) }
        }
        return result
    }
}

public struct PreviewCacheKey: Hashable, Sendable {
    public let value: String

    public init(asset: PhotoAsset, maxPixelSize: Int, pipelineIdentity: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let developRevision = (try? encoder.encode(asset.xmp)).map { String(data: $0, encoding: .utf8) ?? "" } ?? "encode-error"
        let material = [
            asset.fileURL.standardizedFileURL.path,
            String(asset.dateModified.timeIntervalSince1970),
            String(asset.fileSize),
            developRevision,
            String(maxPixelSize),
            pipelineIdentity
        ].joined(separator: "\u{1f}")
        value = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }
}

/// Strict, explicitly accounted LRU cache used only for speculative bitmaps.
public struct PreviewBitmapCache<Value> {
    private struct Entry {
        let value: Value
        let costBytes: Int
        let sequence: UInt64
    }

    public let capacityBytes: Int
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    public private(set) var accountedBytes = 0

    public init(capacityBytes: Int = 128 * 1024 * 1024) {
        self.capacityBytes = max(0, capacityBytes)
    }

    public mutating func value(forKey key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        sequence &+= 1
        entries[key] = Entry(value: entry.value, costBytes: entry.costBytes, sequence: sequence)
        return entry.value
    }

    public mutating func insert(_ value: Value, forKey key: String, costBytes: Int) {
        guard costBytes >= 0, costBytes <= capacityBytes else { return }
        removeValue(forKey: key)
        while accountedBytes + costBytes > capacityBytes, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            removeValue(forKey: oldest)
        }
        sequence &+= 1
        entries[key] = Entry(value: value, costBytes: costBytes, sequence: sequence)
        accountedBytes += costBytes
    }

    public mutating func reserve(_ costBytes: Int) -> Bool {
        guard costBytes >= 0, costBytes <= capacityBytes else { return false }
        while accountedBytes + costBytes > capacityBytes, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            removeValue(forKey: oldest)
        }
        return accountedBytes + costBytes <= capacityBytes
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        accountedBytes = 0
    }

    private mutating func removeValue(forKey key: String) {
        if let removed = entries.removeValue(forKey: key) { accountedBytes -= removed.costBytes }
    }
}

public struct PreviewPreloadJob: Equatable, Sendable {
    public let id: UInt64
    public let generation: UInt64
    public let key: String
}

/// Deterministic one-worker scheduler. Reprioritizing invalidates publication but retains the
/// running slot until the decoder reports completion, even when its task was cancelled.
public struct PreviewPreloadScheduler {
    private(set) var generation: UInt64 = 0
    private var queuedKeys: [String] = []
    private var runningJob: PreviewPreloadJob?
    private var nextID: UInt64 = 0
    private var foregroundSelectionID: String?
    private var completedForegroundSelectionID: String?
    private var isMemorySuspended = false

    public init() {}
    public var runningCount: Int { runningJob == nil ? 0 : 1 }
    public func isForegroundPending(selectionID: String) -> Bool { foregroundSelectionID == selectionID }

    public mutating func reprioritize(keys: [String], cachedKeys: Set<String> = []) {
        generation &+= 1
        var seen = Set<String>()
        queuedKeys = keys.filter { !cachedKeys.contains($0) && seen.insert($0).inserted }
    }

    public mutating func suspendForForeground(selectionID: String) {
        completedForegroundSelectionID = nil
        foregroundSelectionID = selectionID
    }
    public mutating func armForeground(selectionID: String) {
        guard completedForegroundSelectionID != selectionID else { return }
        foregroundSelectionID = selectionID
    }
    public mutating func foregroundCompleted(selectionID: String) {
        if foregroundSelectionID == selectionID {
            foregroundSelectionID = nil
            completedForegroundSelectionID = selectionID
        }
    }
    public mutating func cancelForeground() { foregroundSelectionID = nil; completedForegroundSelectionID = nil }
    public mutating func setMemorySuspended(_ suspended: Bool) { isMemorySuspended = suspended }

    public mutating func cancelAll() {
        generation &+= 1
        queuedKeys.removeAll()
    }

    public mutating func beginNext() -> PreviewPreloadJob? {
        guard runningJob == nil, !queuedKeys.isEmpty, foregroundSelectionID == nil, !isMemorySuspended else { return nil }
        nextID &+= 1
        let job = PreviewPreloadJob(id: nextID, generation: generation, key: queuedKeys.removeFirst())
        runningJob = job
        return job
    }

    @discardableResult
    public mutating func finish(_ job: PreviewPreloadJob, mayPublish: Bool) -> Bool {
        guard runningJob?.id == job.id else { return false }
        runningJob = nil
        return mayPublish && job.generation == generation
    }
}

private struct PreviewBitmap: @unchecked Sendable {
    let image: CGImage
    var costBytes: Int { image.bytesPerRow * image.height }
}

/// Separate low-priority preview-only worker. It never submits work to LiveDevelopPreviewEngine.
public actor PreviewPreloader {
    public static let shared = PreviewPreloader()
    public static let budgetBytes = 128 * 1024 * 1024
    public static let previewSize = 1600
    private static let pipelineIdentity = "imageio-embedded-transformed-rgba-v1"

    private var cache = PreviewBitmapCache<PreviewBitmap>(capacityBytes: budgetBytes)
    private var scheduler = PreviewPreloadScheduler()
    private var assetsByKey: [String: PhotoAsset] = [:]
    private var desiredKeys: [String] = []
    private var worker: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressurePolicy = PreviewMemoryPressurePolicy()

    public init(observeMemoryPressure: Bool = true) {
        if observeMemoryPressure {
            Task { await installMemoryPressureObserver() }
        }
    }

    private func installMemoryPressureObserver() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            let data = source.data
            let level: PreviewMemoryPressureLevel = data.contains(.critical) ? .critical : (data.contains(.warning) ? .warning : .normal)
            Task { await self?.handleMemoryPressure(level) }
        }
        source.resume()
        memoryPressureSource = source
    }

    public func update(assets: [PhotoAsset], selectedID: String?, direction: PreviewTravelDirection) {
        let selectedIndex = assets.firstIndex { $0.id == selectedID }
        let neighborIndices = selectedIndex.map {
            PreviewPreloadPlan.neighborIndices(count: assets.count, selectedIndex: $0, direction: direction)
        } ?? []
        var orderedAssets: [PhotoAsset] = []
        for index in neighborIndices {
            let asset = assets[index]
            guard Self.isSafeToSpeculate(asset) else { InspectionTrace.event("preload.skip_edited_raw"); continue }
            orderedAssets.append(asset)
        }
        let keys = orderedAssets.map { Self.key(for: $0).value }
        assetsByKey = Dictionary(uniqueKeysWithValues: orderedAssets.map { (Self.key(for: $0).value, $0) })
        desiredKeys = keys
        let cachedKeys = Set(keys.filter { cache.value(forKey: $0) != nil })
        scheduler.reprioritize(keys: keys, cachedKeys: cachedKeys)
        worker?.cancel()
        startNextIfIdle()
    }

    public func cachedPreview(for asset: PhotoAsset, maxPixelSize: Int = previewSize) -> NSImage? {
        let key = Self.key(for: asset, maxPixelSize: maxPixelSize).value
        guard let bitmap = cache.value(forKey: key) else { InspectionTrace.event("preload.cache_miss"); return nil }
        InspectionTrace.event("preload.cache_hit")
        return NSImage(cgImage: bitmap.image, size: NSSize(width: bitmap.image.width, height: bitmap.image.height))
    }

    public func cancelAndClear() {
        scheduler.cancelAll()
        worker?.cancel()
        cache.removeAll()
        assetsByKey.removeAll()
        desiredKeys.removeAll()
    }

    public func handleMemoryPressure() {
        handleMemoryPressure(.warning)
    }

    public func handleMemoryPressure(_ level: PreviewMemoryPressureLevel) {
        switch level {
        case .normal: InspectionTrace.event("preload.memory_pressure_normal")
        case .warning: InspectionTrace.event("preload.paused_memory_pressure_warning")
        case .critical: InspectionTrace.event("preload.paused_memory_pressure_critical")
        }
        memoryPressurePolicy.receive(level)
        scheduler.setMemorySuspended(memoryPressurePolicy.isSuspended)
        guard memoryPressurePolicy.isSuspended else {
            let cachedKeys = Set(desiredKeys.filter { cache.value(forKey: $0) != nil })
            scheduler.reprioritize(keys: desiredKeys, cachedKeys: cachedKeys)
            startNextIfIdle()
            return
        }
        scheduler.cancelAll()
        worker?.cancel()
        cache.removeAll()
        scheduler.setMemorySuspended(true)
    }

    public func foregroundSelectionStarted(_ id: String) { InspectionTrace.event("preload.paused_foreground_selection"); scheduler.suspendForForeground(selectionID: id); worker?.cancel() }
    public func armForegroundSelection(_ id: String) { InspectionTrace.event("preload.paused_foreground_armed"); scheduler.armForeground(selectionID: id); worker?.cancel() }
    public func foregroundSelectionCompleted(_ id: String) { scheduler.foregroundCompleted(selectionID: id); startNextIfIdle() }
    public func hasPendingForegroundSelectionForTesting(_ id: String) -> Bool { scheduler.isForegroundPending(selectionID: id) }
    public func cancelForegroundSelection() { scheduler.cancelForeground(); scheduler.cancelAll(); worker?.cancel() }
    public func foregroundSelectionEnded() { scheduler.cancelForeground(); startNextIfIdle() }

    public static func isSafeToSpeculate(_ asset: PhotoAsset) -> Bool {
        // Thumbnail RAW edit rendering currently falls through to an embedded preview on failure.
        // Skip edited RAW entirely so this path cannot publish an unprocessed/wrong-color result.
        !(asset.isRaw && asset.xmp.hasDevelopEdits)
    }

    private static func key(for asset: PhotoAsset, maxPixelSize: Int = previewSize) -> PreviewCacheKey {
        PreviewCacheKey(asset: asset, maxPixelSize: maxPixelSize, pipelineIdentity: pipelineIdentity)
    }

    private func startNextIfIdle() {
        guard worker == nil else { InspectionTrace.event("preload.paused_worker_busy"); return }
        guard let job = scheduler.beginNext() else {
            if scheduler.runningCount > 0 { InspectionTrace.event("preload.paused_running_job") }
            else if desiredKeys.isEmpty { InspectionTrace.event("preload.paused_no_neighbors") }
            else { InspectionTrace.event("preload.paused_foreground_or_memory") }
            return
        }
        guard let asset = assetsByKey[job.key] else { InspectionTrace.event("preload.skip_missing_asset"); return }
        // Reserve twice the RGBA estimate before dispatch to account for row padding and larger
        // component formats. Actual materialized bytes are checked again on admission.
        let reservation = Self.previewSize * Self.previewSize * 8
        guard cache.reserve(reservation) else {
            InspectionTrace.event("preload.skip_budget_reservation")
            _ = scheduler.finish(job, mayPublish: false)
            startNextIfIdle()
            return
        }
        let key = job.key
        worker = Task.detached(priority: .utility) { [weak self] in
            let bitmap = Self.decodeEmbeddedPreview(for: asset, maxPixelSize: Self.previewSize)
            let mayPublish = !Task.isCancelled
            await self?.finish(job, bitmap: bitmap, cacheKey: key, mayPublish: mayPublish)
        }
    }

    private func finish(_ job: PreviewPreloadJob, bitmap: PreviewBitmap?, cacheKey: String, mayPublish: Bool) {
        let accepted = scheduler.finish(job, mayPublish: mayPublish)
        if accepted, let bitmap {
            cache.insert(bitmap, forKey: cacheKey, costBytes: bitmap.costBytes)
        }
        worker = nil
        startNextIfIdle()
    }

    private nonisolated static func decodeEmbeddedPreview(for asset: PhotoAsset, maxPixelSize: Int) -> PreviewBitmap? {
        let options = thumbnailOptions(isRaw: asset.isRaw, maxPixelSize: maxPixelSize)
        guard let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PreviewBitmap(image: image)
    }

    public static func thumbnailOptions(isRaw: Bool, maxPixelSize: Int = previewSize) -> [CFString: Any] {
        [kCGImageSourceShouldCache: false, kCGImageSourceCreateThumbnailFromImageAlways: !isRaw,
         kCGImageSourceCreateThumbnailFromImageIfAbsent: false, kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
    }
}
