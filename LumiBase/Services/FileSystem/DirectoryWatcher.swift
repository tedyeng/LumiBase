import Foundation

/// Observes a directory on disk for file additions, removals, and XMP changes
public final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private let queue = DispatchQueue(label: "com.lumibase.watcher", qos: .utility)
    
    public var onChange: (@Sendable () -> Void)?
    
    public init() {}
    
    public func startWatching(url: URL) {
        stopWatching()
        
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .revoke],
            queue: queue
        )
        
        dispatchSource.setEventHandler { [weak self] in
            // Debounce rapid events
            DispatchQueue.main.async {
                self?.onChange?()
            }
        }
        
        dispatchSource.setCancelHandler { [fileDescriptor = self.fileDescriptor] in
            close(fileDescriptor)
        }
        
        self.source = dispatchSource
        dispatchSource.resume()
    }
    
    public func stopWatching() {
        if let source = source {
            source.cancel()
            self.source = nil
        }
    }
    
    deinit {
        stopWatching()
    }
}
