import Foundation

/// Filter criteria for Library search, rating, flag, and color label filtering
public struct FilterCriteria: Equatable, Sendable {
    public var minimumRating: Int // 0 to 5
    public var ratingExact: Bool // If true, matches exact rating instead of >=
    public var selectedFlag: FlagStatus? // nil means all
    public var selectedColorLabels: Set<ColorLabel>
    public var searchText: String
    public var showRawOnly: Bool
    public var dateRange: ClosedRange<Date>?
    
    public init(
        minimumRating: Int = 0,
        ratingExact: Bool = false,
        selectedFlag: FlagStatus? = nil,
        selectedColorLabels: Set<ColorLabel> = [],
        searchText: String = "",
        showRawOnly: Bool = false,
        dateRange: ClosedRange<Date>? = nil
    ) {
        self.minimumRating = minimumRating
        self.ratingExact = ratingExact
        self.selectedFlag = selectedFlag
        self.selectedColorLabels = selectedColorLabels
        self.searchText = searchText
        self.showRawOnly = showRawOnly
        self.dateRange = dateRange
    }
    
    public var isActive: Bool {
        minimumRating > 0 ||
        selectedFlag != nil ||
        !selectedColorLabels.isEmpty ||
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        showRawOnly ||
        dateRange != nil
    }
    
    public mutating func reset() {
        self = FilterCriteria()
    }
    
    /// Evaluates whether a given PhotoAsset matches the filter
    public func matches(asset: PhotoAsset) -> Bool {
        // Rating check
        if minimumRating > 0 {
            if ratingExact {
                if asset.xmp.rating != minimumRating { return false }
            } else {
                if asset.xmp.rating < minimumRating { return false }
            }
        }
        
        // Flag check
        if let flag = selectedFlag {
            if asset.xmp.flag != flag { return false }
        }
        
        // Color label check
        if !selectedColorLabels.isEmpty {
            if !selectedColorLabels.contains(asset.xmp.colorLabel) { return false }
        }
        
        // RAW only check
        if showRawOnly && !asset.isRaw {
            return false
        }
        
        // Search text check
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            let matchesFilename = asset.filename.lowercased().contains(query)
            let matchesKeywords = asset.xmp.keywords.contains { $0.lowercased().contains(query) }
            let matchesCamera = (asset.cameraMetadata.model ?? "").lowercased().contains(query)
            let matchesLens = (asset.cameraMetadata.lensModel ?? "").lowercased().contains(query)
            let matchesTitle = (asset.xmp.title ?? "").lowercased().contains(query)
            
            if !(matchesFilename || matchesKeywords || matchesCamera || matchesLens || matchesTitle) {
                return false
            }
        }
        
        // Date range check
        if let range = dateRange {
            let targetDate = asset.cameraMetadata.captureDate ?? asset.dateCreated
            if !range.contains(targetDate) { return false }
        }
        
        return true
    }
}

/// Sort criteria for Library Grid
public enum AssetSortOrder: String, CaseIterable, Identifiable {
    case captureDateAscending = "Capture Time (Oldest first)"
    case captureDateDescending = "Capture Time (Newest first)"
    case filenameAscending = "File Name (A-Z)"
    case filenameDescending = "File Name (Z-A)"
    case ratingDescending = "Rating (Highest first)"
    case ratingAscending = "Rating (Lowest first)"
    case fileSizeDescending = "File Size (Largest first)"
    
    public var id: String { rawValue }
}
