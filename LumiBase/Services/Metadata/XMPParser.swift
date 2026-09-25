import Foundation

/// Robust parser for Adobe Lightroom standard XMP sidecar files
public final class XMPParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    
    /// Parses an XMP file from disk or raw Data
    public static func parse(url: URL) -> XMPMetadata {
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        var metadata = parse(data: data)
        metadata.isLoadedFromSidecar = true
        metadata.sidecarFilename = url.lastPathComponent
        return metadata
    }
    
    public static func parse(data: Data) -> XMPMetadata {
        let parser = XMPParser()
        return parser.parseData(data)
    }
    
    // Internal parser state
    private var currentText: String = ""
    private var currentElement: String = ""
    
    private var parsedRating: Int = 0
    private var parsedLabel: ColorLabel = .none
    private var parsedFlag: FlagStatus = .unflagged
    private var parsedKeywords: [String] = []
    private var parsedTitle: String?
    private var parsedCaption: String?
    private var parsedCreator: String?
    private var parsedCopyright: String?
    private var parsedDate: Date?
    
    // Develop settings
    private var parsedExposure: Double?
    private var parsedTemperature: Int?
    private var parsedTint: Int?
    private var parsedContrast: Int?
    private var parsedHighlights: Int?
    private var parsedShadows: Int?
    private var parsedWhites: Int?
    private var parsedBlacks: Int?
    private var parsedDehaze: Int?
    private var parsedVibrance: Int?
    private var parsedSaturation: Int?
    private var parsedClarity: Int?
    private var parsedTexture: Int?
    private var parsedHasCrop: Bool = false
    private var parsedCropTop: Double?
    private var parsedCropLeft: Double?
    private var parsedCropBottom: Double?
    private var parsedCropRight: Double?
    private var parsedCropAngle: Double?
    private var parsedCameraProfile: String?
    private var parsedConvertToGrayscale: Bool?
    
    private var inSubjectBag: Bool = false
    private var inTitleAlt: Bool = false
    private var inDescriptionAlt: Bool = false
    
    public func parseData(_ data: Data) -> XMPMetadata {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldReportNamespacePrefixes = false
        xmlParser.shouldResolveExternalEntities = false
        
        if xmlParser.parse() {
            return XMPMetadata(
                isLoadedFromSidecar: true,
                rating: parsedRating,
                colorLabel: parsedLabel,
                flag: parsedFlag,
                keywords: parsedKeywords,
                title: parsedTitle,
                caption: parsedCaption,
                creator: parsedCreator,
                copyright: parsedCopyright,
                ratingDate: parsedDate,
                exposure2012: parsedExposure,
                temperature: parsedTemperature,
                tint: parsedTint,
                contrast2012: parsedContrast,
                highlights2012: parsedHighlights,
                shadows2012: parsedShadows,
                whites2012: parsedWhites,
                blacks2012: parsedBlacks,
                dehaze: parsedDehaze,
                vibrance: parsedVibrance,
                saturation: parsedSaturation,
                clarity2012: parsedClarity,
                texture: parsedTexture,
                hasCrop: parsedHasCrop,
                cropTop: parsedCropTop,
                cropLeft: parsedCropLeft,
                cropBottom: parsedCropBottom,
                cropRight: parsedCropRight,
                cropAngle: parsedCropAngle,
                cameraProfile: parsedCameraProfile,
                convertToGrayscale: parsedConvertToGrayscale
            )
        }
        
        // Fallback to regex parser if XML is malformed
        if let stringContent = String(data: data, encoding: .utf8) {
            return parseWithStringMatching(stringContent)
        }
        
        return .empty
    }
    
    // MARK: - XMLParserDelegate
    
    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        
        // Check attributes (e.g. xmp:Rating="4", crs:Pick="1", crs:Exposure2012="+0.50")
        for (rawKey, val) in attributeDict {
            let key = rawKey.lowercased()
            if key.hasSuffix("rating") || key == "rating" {
                if let r = Int(val) {
                    parsedRating = max(0, min(5, r))
                }
            } else if key.hasSuffix("label") || key == "label" {
                parsedLabel = parseColorLabel(val)
            } else if key.hasSuffix("pick") || key.hasSuffix("flag") || key == "pick" || key == "flag" {
                parsedFlag = parseFlag(val)
            } else if key.hasSuffix("exposure2012") || key.hasSuffix("exposure") {
                parsedExposure = Double(val)
            } else if key.hasSuffix("temperature") {
                parsedTemperature = Int(val)
            } else if key.hasSuffix("tint") {
                parsedTint = Int(val)
            } else if key.hasSuffix("contrast2012") {
                parsedContrast = Int(val)
            } else if key.hasSuffix("highlights2012") {
                parsedHighlights = Int(val)
            } else if key.hasSuffix("shadows2012") {
                parsedShadows = Int(val)
            } else if key.hasSuffix("whites2012") {
                parsedWhites = Int(val)
            } else if key.hasSuffix("blacks2012") {
                parsedBlacks = Int(val)
            } else if key.hasSuffix("dehaze") {
                parsedDehaze = Int(val)
            } else if key.hasSuffix("vibrance") {
                parsedVibrance = Int(val)
            } else if key.hasSuffix("saturation") {
                parsedSaturation = Int(val)
            } else if key.hasSuffix("clarity2012") || key.hasSuffix("clarity") {
                parsedClarity = Int(val)
            } else if key.hasSuffix("texture") {
                parsedTexture = Int(val)
            } else if key.hasSuffix("hascrop") {
                parsedHasCrop = (val.lowercased() == "true" || val == "1")
            } else if key.hasSuffix("croptop") {
                parsedCropTop = Double(val)
            } else if key.hasSuffix("cropleft") {
                parsedCropLeft = Double(val)
            } else if key.hasSuffix("cropbottom") {
                parsedCropBottom = Double(val)
            } else if key.hasSuffix("cropright") {
                parsedCropRight = Double(val)
            } else if key.hasSuffix("cropangle") {
                parsedCropAngle = Double(val)
            } else if key.hasSuffix("cameraprofile") {
                parsedCameraProfile = val
            } else if key.hasSuffix("converttograyscale") {
                parsedConvertToGrayscale = (val.lowercased() == "true" || val == "1")
            }
        }
        
        let lowerElement = elementName.lowercased()
        if lowerElement.hasSuffix("subject") {
            inSubjectBag = true
        } else if lowerElement.hasSuffix("title") {
            inTitleAlt = true
        } else if lowerElement.hasSuffix("description") {
            inDescriptionAlt = true
        }
    }
    
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerElement = elementName.lowercased()
        
        if lowerElement.hasSuffix("rating") {
            if let r = Int(trimmed) {
                parsedRating = max(0, min(5, r))
            }
        } else if lowerElement.hasSuffix("label") {
            parsedLabel = parseColorLabel(trimmed)
        } else if lowerElement.hasSuffix("pick") || lowerElement.hasSuffix("flag") {
            parsedFlag = parseFlag(trimmed)
        } else if lowerElement.hasSuffix("exposure2012") || lowerElement.hasSuffix("exposure") {
            parsedExposure = Double(trimmed)
        } else if lowerElement.hasSuffix("temperature") {
            parsedTemperature = Int(trimmed)
        } else if lowerElement.hasSuffix("tint") {
            parsedTint = Int(trimmed)
        } else if lowerElement.hasSuffix("contrast2012") {
            parsedContrast = Int(trimmed)
        } else if lowerElement.hasSuffix("hascrop") {
            parsedHasCrop = (trimmed.lowercased() == "true" || trimmed == "1")
        } else if lowerElement.hasSuffix("croptop") {
            parsedCropTop = Double(trimmed)
        } else if lowerElement.hasSuffix("cropleft") {
            parsedCropLeft = Double(trimmed)
        } else if lowerElement.hasSuffix("cropbottom") {
            parsedCropBottom = Double(trimmed)
        } else if lowerElement.hasSuffix("cropright") {
            parsedCropRight = Double(trimmed)
        } else if lowerElement.hasSuffix("cropangle") {
            parsedCropAngle = Double(trimmed)
        } else if lowerElement.hasSuffix("li") {
            if inSubjectBag && !trimmed.isEmpty && !parsedKeywords.contains(trimmed) {
                parsedKeywords.append(trimmed)
            } else if inTitleAlt && !trimmed.isEmpty {
                parsedTitle = trimmed
            } else if inDescriptionAlt && !trimmed.isEmpty {
                parsedCaption = trimmed
            }
        } else if lowerElement.hasSuffix("creator") {
            if !trimmed.isEmpty {
                parsedCreator = trimmed
            }
        } else if lowerElement.hasSuffix("rights") || lowerElement.hasSuffix("copyright") {
            if !trimmed.isEmpty {
                parsedCopyright = trimmed
            }
        }
        
        if lowerElement.hasSuffix("subject") {
            inSubjectBag = false
        } else if lowerElement.hasSuffix("title") {
            inTitleAlt = false
        } else if lowerElement.hasSuffix("description") {
            inDescriptionAlt = false
        }
    }
    
    private func parseColorLabel(_ value: String) -> ColorLabel {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .none
        }
    }
    
    private func parseFlag(_ value: String) -> FlagStatus {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean == "1" || clean == "pick" || clean == "picked" || clean == "true" {
            return .pick
        } else if clean == "-1" || clean == "reject" || clean == "rejected" {
            return .reject
        }
        return .unflagged
    }
    
    // MARK: - Regex Fallback
    
    private func parseWithStringMatching(_ content: String) -> XMPMetadata {
        var rating = 0
        var label = ColorLabel.none
        var flag = FlagStatus.unflagged
        var keywords: [String] = []
        var title: String?
        var caption: String?
        var exposure: Double?
        var temperature: Int?
        var tint: Int?
        var contrast: Int?
        var highlights: Int?
        var shadows: Int?
        var whites: Int?
        var blacks: Int?
        var dehaze: Int?
        var vibrance: Int?
        var saturation: Int?
        var clarity: Int?
        var texture: Int?
        var cameraProfile: String?
        var hasCrop = false
        
        if let ratingMatch = matchFirst(pattern: #"(?:Rating="|<[^:>]+:Rating>)([0-5])"#, in: content) {
            rating = Int(ratingMatch) ?? 0
        }
        
        if let labelMatch = matchFirst(pattern: #"(?:Label="|<[^:>]+:Label>)([A-Za-z]+)"#, in: content) {
            label = parseColorLabel(labelMatch)
        }
        
        if let flagMatch = matchFirst(pattern: #"(?:Pick|Flag)="?(-?1|pick|reject)"#, in: content) {
            flag = parseFlag(flagMatch)
        }
        
        if let expMatch = matchFirst(pattern: #"Exposure2012="([+-]?\d+(?:\.\d+)?)"#, in: content) {
            exposure = Double(expMatch)
        }
        
        if let tempMatch = matchFirst(pattern: #"Temperature="(\d+)"#, in: content) {
            temperature = Int(tempMatch)
        }
        
        if let tintMatch = matchFirst(pattern: #"Tint="([+-]?\d+)"#, in: content) {
            tint = Int(tintMatch)
        }
        
        if let contrastMatch = matchFirst(pattern: #"Contrast2012="([+-]?\d+)"#, in: content) {
            contrast = Int(contrastMatch)
        }
        
        if let hlMatch = matchFirst(pattern: #"Highlights2012="([+-]?\d+)"#, in: content) {
            highlights = Int(hlMatch)
        }
        
        if let shMatch = matchFirst(pattern: #"Shadows2012="([+-]?\d+)"#, in: content) {
            shadows = Int(shMatch)
        }
        
        if let wMatch = matchFirst(pattern: #"Whites2012="([+-]?\d+)"#, in: content) {
            whites = Int(wMatch)
        }
        
        if let bMatch = matchFirst(pattern: #"Blacks2012="([+-]?\d+)"#, in: content) {
            blacks = Int(bMatch)
        }
        
        if let texMatch = matchFirst(pattern: #"Texture="([+-]?\d+)"#, in: content) {
            texture = Int(texMatch)
        }
        
        if let clarMatch = matchFirst(pattern: #"Clarity2012="([+-]?\d+)"#, in: content) {
            clarity = Int(clarMatch)
        }
        
        if let dehazeMatch = matchFirst(pattern: #"Dehaze="([+-]?\d+)"#, in: content) {
            dehaze = Int(dehazeMatch)
        }
        
        if let vibMatch = matchFirst(pattern: #"Vibrance="([+-]?\d+)"#, in: content) {
            vibrance = Int(vibMatch)
        }
        
        if let satMatch = matchFirst(pattern: #"Saturation="([+-]?\d+)"#, in: content) {
            saturation = Int(satMatch)
        }
        
        if let profMatch = matchFirst(pattern: #"CameraProfile="([^"]+)""#, in: content) {
            cameraProfile = profMatch
        }
        
        if let cropMatch = matchFirst(pattern: #"HasCrop="(true|1)""#, in: content) {
            hasCrop = !cropMatch.isEmpty
        }
        
        var cropTop: Double? = nil
        var cropLeft: Double? = nil
        var cropBottom: Double? = nil
        var cropRight: Double? = nil
        var cropAngle: Double? = nil
        if let match = matchFirst(pattern: #"CropTop="([^"]+)""#, in: content) { cropTop = Double(match) }
        if let match = matchFirst(pattern: #"CropLeft="([^"]+)""#, in: content) { cropLeft = Double(match) }
        if let match = matchFirst(pattern: #"CropBottom="([^"]+)""#, in: content) { cropBottom = Double(match) }
        if let match = matchFirst(pattern: #"CropRight="([^"]+)""#, in: content) { cropRight = Double(match) }
        if let match = matchFirst(pattern: #"CropAngle="([^"]+)""#, in: content) { cropAngle = Double(match) }
        if cropTop != nil || cropLeft != nil || cropBottom != nil || cropRight != nil || cropAngle != nil {
            hasCrop = true
        }
        
        let keywordMatches = matchAll(pattern: #"<[^:>]+:li>([^<]+)</[^:>]+:li>"#, in: content)
        for kw in keywordMatches {
            let clean = kw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !keywords.contains(clean) {
                keywords.append(clean)
            }
        }
        
        if let titleMatch = matchFirst(pattern: #"<dc:title>[^<]*<rdf:Alt>[^<]*<rdf:li[^>]*>([^<]+)</rdf:li>"#, in: content) {
            title = titleMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        if let descMatch = matchFirst(pattern: #"<dc:description>[^<]*<rdf:Alt>[^<]*<rdf:li[^>]*>([^<]+)</rdf:li>"#, in: content) {
            caption = descMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var convertToGrayscale: Bool? = nil
        if let grayMatch = matchFirst(pattern: #"ConvertToGrayscale="(true|1)""#, in: content) {
            convertToGrayscale = !grayMatch.isEmpty
        }
        
        return XMPMetadata(
            isLoadedFromSidecar: true,
            rating: rating,
            colorLabel: label,
            flag: flag,
            keywords: keywords,
            title: title,
            caption: caption,
            exposure2012: exposure,
            temperature: temperature,
            tint: tint,
            contrast2012: contrast,
            highlights2012: highlights,
            shadows2012: shadows,
            whites2012: whites,
            blacks2012: blacks,
            dehaze: dehaze,
            vibrance: vibrance,
            saturation: saturation,
            clarity2012: clarity,
            texture: texture,
            hasCrop: hasCrop,
            cropTop: cropTop,
            cropLeft: cropLeft,
            cropBottom: cropBottom,
            cropRight: cropRight,
            cropAngle: cropAngle,
            cameraProfile: cameraProfile,
            convertToGrayscale: convertToGrayscale
        )
    }
    
    private func matchFirst(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsString = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        return range.location != NSNotFound ? nsString.substring(with: range) : nil
    }
    
    private func matchAll(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            let range = match.range(at: 1)
            return range.location != NSNotFound ? nsString.substring(with: range) : nil
        }
    }
}
