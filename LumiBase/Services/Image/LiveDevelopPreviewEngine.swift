import Foundation
import AppKit
import CoreImage

/// Dedicated coalescing background render engine for zero-latency 120fps develop adjustments
public final class LiveDevelopPreviewEngine: @unchecked Sendable {
    public static let shared = LiveDevelopPreviewEngine()
    
    private let renderQueue = DispatchQueue(label: "com.lumibase.livepreview.engine", qos: .userInteractive)
    private let lock = NSLock()
    private var isRendering: Bool = false
    private var pendingRequest: RenderRequest?
    
    public typealias RenderCompletion = @MainActor @Sendable (NSImage?) -> Void
    
    public struct RenderRequest: Sendable {
        public let baseHolder: BaseImageHolder
        public let cameraModel: String?
        public let xmp: XMPMetadata?
        public let interactive: Bool
        public let fullResolution: Bool
        public let completion: RenderCompletion
        
        public init(
            baseHolder: BaseImageHolder,
            cameraModel: String?,
            xmp: XMPMetadata?,
            interactive: Bool,
            fullResolution: Bool = false,
            completion: @escaping RenderCompletion
        ) {
            self.baseHolder = baseHolder
            self.cameraModel = cameraModel
            self.xmp = xmp
            self.interactive = interactive
            self.fullResolution = fullResolution
            self.completion = completion
        }
    }
    
    private init() {}
    
    /// Requests a processed image render. Coalesces rapid requests so only the latest slider frame is computed.
    public func requestRender(
        baseHolder: BaseImageHolder,
        cameraModel: String?,
        xmp: XMPMetadata?,
        interactive: Bool = true,
        fullResolution: Bool = false,
        completion: @escaping RenderCompletion
    ) {
        let request = RenderRequest(
            baseHolder: baseHolder,
            cameraModel: cameraModel,
            xmp: xmp,
            interactive: interactive,
            fullResolution: fullResolution,
            completion: completion
        )
        
        lock.lock()
        pendingRequest = request
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
                guard let current = self.pendingRequest else {
                    self.isRendering = false
                    self.lock.unlock()
                    break
                }
                self.pendingRequest = nil
                self.lock.unlock()
                
                // Execute GPU processing completely off the main thread
                let image = RAWImageLoader.shared.renderProcessed(
                    baseHolder: current.baseHolder,
                    cameraModel: current.cameraModel,
                    xmp: current.xmp,
                    interactive: current.interactive,
                    fullResolution: current.fullResolution
                )
                DispatchQueue.main.async {
                    current.completion(image)
                }
            }
        }
    }
}
