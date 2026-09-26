import Foundation
import AppKit
import CoreImage

/// Serial coalescing render engine. Completion is raster-ready, not display-present.
public final class LiveDevelopPreviewEngine: @unchecked Sendable {
    public static let shared = LiveDevelopPreviewEngine()
    
    private let renderQueue = DispatchQueue(label: "com.lumibase.livepreview.engine", qos: .userInteractive)
    private let lock = NSLock()
    private var isRendering: Bool = false
    private struct Work {
        let request: RenderRequest
        let revision: UInt64
        let enqueuedAt: Double
    }
    private var pendingRequest: Work?
    private var revision: UInt64 = 0
    struct Statistics {
        var submitted = 0
        var started = 0
        var coalesced = 0
        var discarded = 0
        var published = 0
        var lastQueueMilliseconds = 0.0
        var lastRenderMilliseconds = 0.0
        var lastCallbackMilliseconds = 0.0
    }
    private var counters = Statistics()
    var statistics: Statistics { lock.lock(); defer { lock.unlock() }; return counters }
    private func isCurrent(_ ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return ticket == revision
    }
    /// Invalidates obsolete work immediately, including during the native ROI
    /// throttle / Fit idle delay. An active Core Image draw cannot be interrupted.
    func cancelPending() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        if pendingRequest != nil { counters.coalesced += 1 }
        pendingRequest = nil
    }
    
    public typealias RenderCompletion = @MainActor @Sendable (NSImage?) -> Void
    
    public struct RenderRequest: Sendable {
        public let baseHolder: BaseImageHolder
        public let cameraModel: String?
        public let xmp: XMPMetadata?
        public let interactive: Bool
        public let fullResolution: Bool
        public let sourceRect: CGRect?
        public let completion: RenderCompletion
        
        public init(
            baseHolder: BaseImageHolder,
            cameraModel: String?,
            xmp: XMPMetadata?,
            interactive: Bool,
            fullResolution: Bool = false,
            sourceRect: CGRect? = nil,
            completion: @escaping RenderCompletion
        ) {
            self.baseHolder = baseHolder
            self.cameraModel = cameraModel
            self.xmp = xmp
            self.interactive = interactive
            self.fullResolution = fullResolution
            self.sourceRect = sourceRect
            self.completion = completion
        }
    }
    
    private let renderer: (@Sendable (RenderRequest) -> NSImage?)?
    init(renderer: (@Sendable (RenderRequest) -> NSImage?)? = nil) { self.renderer = renderer }
    
    /// Requests a processed image render. Coalesces rapid requests so only the latest slider frame is computed.
    public func requestRender(
        baseHolder: BaseImageHolder,
        cameraModel: String?,
        xmp: XMPMetadata?,
        interactive: Bool = true,
        fullResolution: Bool = false,
        sourceRect: CGRect? = nil,
        completion: @escaping RenderCompletion
    ) {
        let request = RenderRequest(
            baseHolder: baseHolder,
            cameraModel: cameraModel,
            xmp: xmp,
            interactive: interactive,
            fullResolution: fullResolution,
            sourceRect: sourceRect,
            completion: completion
        )
        
        lock.lock()
        revision &+= 1
        counters.submitted += 1
        if pendingRequest != nil { counters.coalesced += 1 }
        pendingRequest = Work(request: request, revision: revision, enqueuedAt: ProcessInfo.processInfo.systemUptime)
        if !isRendering {
            isRendering = true
            lock.unlock()
            dispatchNext()
        } else {
            lock.unlock()
        }
    }
    
    private func dispatchNext() {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            
            while true {
                self.lock.lock()
                guard let work = self.pendingRequest else {
                    self.isRendering = false
                    self.lock.unlock()
                    break
                }
                self.pendingRequest = nil
                self.counters.started += 1
                let start = ProcessInfo.processInfo.systemUptime
                self.counters.lastQueueMilliseconds = (start - work.enqueuedAt) * 1000
                self.lock.unlock()
                let current = work.request
                InspectionTrace.event(current.fullResolution ? (current.sourceRect == nil ? "renderer.start_native_full" : "renderer.start_native_roi") : (current.interactive ? "renderer.start_fit_interactive" : "renderer.start_fit_full"))
                
                // Execute GPU processing completely off the main thread
                let image = self.renderer.map { $0(current) } ?? RAWImageLoader.shared.renderProcessed(
                    baseHolder: current.baseHolder,
                    cameraModel: current.cameraModel,
                    xmp: current.xmp,
                    interactive: current.interactive,
                    fullResolution: current.fullResolution,
                    sourceRect: current.sourceRect,
                    isCurrent: { self.isCurrent(work.revision) }
                )
                self.lock.lock()
                self.counters.lastRenderMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.lock.unlock()
                InspectionTrace.event(current.fullResolution ? (current.sourceRect == nil ? "renderer.complete_native_full" : "renderer.complete_native_roi") : (current.interactive ? "renderer.complete_fit_interactive" : "renderer.complete_fit_full"))
                DispatchQueue.main.async {
                    self.lock.lock()
                    guard work.revision == self.revision else {
                        self.counters.discarded += 1
                        self.lock.unlock()
                        return
                    }
                    self.counters.published += 1
                    self.counters.lastCallbackMilliseconds = (ProcessInfo.processInfo.systemUptime - work.enqueuedAt) * 1000
                    self.lock.unlock()
                    current.completion(image)
                }
            }
        }
    }
}
