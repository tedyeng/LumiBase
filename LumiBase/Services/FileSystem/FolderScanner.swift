import Foundation

/// Fast asynchronous scanner for photo assets and XMP sidecars in a directory
public final class FolderScanner: Sendable {
    
    /// Instant shallow scan to get file list in milliseconds
    public static func quickScan(url: URL) -> [PhotoAsset] {
        let fileManager = FileManager.default
        let supportedExtensions = SupportedFileType.allExtensions
        
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        let filtered = fileURLs.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        
        return filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { fileURL in
                PhotoAsset(
                    fileURL: fileURL,
                    fileSize: (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0,
                    dateModified: (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(),
                    dateCreated: Date(),
                    xmp: .empty,
                    cameraMetadata: .empty
                )
            }
    }
    
    /// Scans a directory URL for supported RAW and image files with full metadata and XMP sidecars
    public static func scanDirectory(
        url: URL,
        recursive: Bool = false,
        onAssetFound: (@Sendable (PhotoAsset) -> Void)? = nil
    ) async -> [PhotoAsset] {
        let fileManager = FileManager.default
        let supportedExtensions = SupportedFileType.allExtensions
        
        var imageURLs: [URL] = []
        
        if recursive {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    let ext = fileURL.pathExtension.lowercased()
                    if supportedExtensions.contains(ext) {
                        imageURLs.append(fileURL)
                    }
                }
            }
        } else {
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                imageURLs = contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            }
        }
        
        // Concurrently process metadata and XMP sidecars in parallel
        return await withTaskGroup(of: PhotoAsset?.self, returning: [PhotoAsset].self) { group in
            for fileURL in imageURLs {
                group.addTask {
                    return parseAsset(fileURL: fileURL)
                }
            }
            
            var results: [PhotoAsset] = []
            for await asset in group {
                if let asset = asset {
                    results.append(asset)
                    onAssetFound?(asset)
                }
            }
            
            // Sort by capture date (oldest first) by default
            return results.sorted { a, b in
                let dateA = a.cameraMetadata.captureDate ?? a.dateCreated
                let dateB = b.cameraMetadata.captureDate ?? b.dateCreated
                return dateA < dateB
            }
        }
    }
    
    /// Parses a single asset on disk, reading XMP sidecar if present and reading EXIF
    public static func parseAsset(fileURL: URL) -> PhotoAsset? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let dateModified = (attributes[.modificationDate] as? Date) ?? Date()
        let dateCreated = (attributes[.creationDate] as? Date) ?? Date()
        
        // 1. Read EXIF & Camera metadata
        let (cameraMetadata, embeddedXMP) = MetadataReader.readMetadata(from: fileURL)
        
        // 2. Read XMP sidecar if present
        var xmpMetadata = embeddedXMP ?? .empty
        let parentDir = fileURL.deletingLastPathComponent()
        
        // Support DSC0001.ARW.xmp AND DSC0001.xmp
        let directXmp = parentDir.appendingPathComponent("\(fileURL.lastPathComponent).xmp")
        let baseNameXmp = parentDir.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).xmp")
        
        if fileManager.fileExists(atPath: directXmp.path) {
            xmpMetadata = XMPParser.parse(url: directXmp)
        } else if fileManager.fileExists(atPath: baseNameXmp.path) {
            xmpMetadata = XMPParser.parse(url: baseNameXmp)
        }
        
        return PhotoAsset(
            fileURL: fileURL,
            fileSize: fileSize,
            dateModified: dateModified,
            dateCreated: dateCreated,
            xmp: xmpMetadata,
            cameraMetadata: cameraMetadata
        )
    }
}
