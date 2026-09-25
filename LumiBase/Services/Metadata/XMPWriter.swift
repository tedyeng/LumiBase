import Foundation

/// Writer for standard Adobe XMP sidecar files
public final class XMPWriter: Sendable {
    
    /// Writes or updates an XMP sidecar file for a given photo
    public static func write(metadata: XMPMetadata, to url: URL, originalFilename: String? = nil) throws {
        let xmpContent = generateXMPXML(metadata: metadata, originalFilename: originalFilename)
        guard let data = xmpContent.data(using: .utf8) else {
            throw NSError(domain: "LumiBase.XMPWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode XMP string as UTF-8"])
        }
        
        try data.write(to: url, options: .atomic)
    }
    
    /// Generates valid Adobe Lightroom-compatible XMP Packet XML
    public static func generateXMPXML(metadata: XMPMetadata, originalFilename: String? = nil) -> String {
        let rawFileNameAttr = originalFilename != nil ? " crs:RawFileName=\"\(escapeXML(originalFilename!))\"" : ""
        let ratingAttr = " xmp:Rating=\"\(metadata.rating)\""
        let labelAttr = metadata.colorLabel != .none ? " xmp:Label=\"\(metadata.colorLabel.rawValue)\"" : ""
        let flagAttr: String
        switch metadata.flag {
        case .pick: flagAttr = " crs:Pick=\"1\""
        case .reject: flagAttr = " crs:Pick=\"-1\""
        case .unflagged: flagAttr = ""
        }
        
        var keywordsXML = ""
        if !metadata.keywords.isEmpty {
            let items = metadata.keywords.map { "      <rdf:li>\(escapeXML($0))</rdf:li>" }.joined(separator: "\n")
            keywordsXML = """
                <dc:subject>
                 <rdf:Bag>
            \(items)
                 </rdf:Bag>
                </dc:subject>
            """
        }
        
        var titleXML = ""
        if let title = metadata.title, !title.isEmpty {
            titleXML = """
                <dc:title>
                 <rdf:Alt>
                  <rdf:li xml:lang="x-default">\(escapeXML(title))</rdf:li>
                 </rdf:Alt>
                </dc:title>
            """
        }
        
        var captionXML = ""
        if let caption = metadata.caption, !caption.isEmpty {
            captionXML = """
                <dc:description>
                 <rdf:Alt>
                  <rdf:li xml:lang="x-default">\(escapeXML(caption))</rdf:li>
                 </rdf:Alt>
                </dc:description>
            """
        }
        
        var developAttrs = ""
        if metadata.hasDevelopEdits {
            developAttrs += " crs:ProcessVersion=\"15.4\""
            if let exp = metadata.exposure2012 {
                developAttrs += String(format: " crs:Exposure2012=\"%+.2f\"", exp)
            }
            if let temp = metadata.temperature {
                developAttrs += " crs:Temperature=\"\(temp)\""
                developAttrs += " crs:WhiteBalance=\"Custom\""
            }
            if let tint = metadata.tint {
                developAttrs += String(format: " crs:Tint=\"%+d\"", tint)
            }
            if let contrast = metadata.contrast2012 {
                developAttrs += String(format: " crs:Contrast2012=\"%+d\"", contrast)
            }
            if let hl = metadata.highlights2012 {
                developAttrs += String(format: " crs:Highlights2012=\"%+d\"", hl)
            }
            if let sh = metadata.shadows2012 {
                developAttrs += String(format: " crs:Shadows2012=\"%+d\"", sh)
            }
            if let w = metadata.whites2012 {
                developAttrs += String(format: " crs:Whites2012=\"%+d\"", w)
            }
            if let b = metadata.blacks2012 {
                developAttrs += String(format: " crs:Blacks2012=\"%+d\"", b)
            }
            if let tex = metadata.texture {
                developAttrs += String(format: " crs:Texture=\"%+d\"", tex)
            }
            if let clarity = metadata.clarity2012 {
                developAttrs += String(format: " crs:Clarity2012=\"%+d\"", clarity)
            }
            if let dehaze = metadata.dehaze {
                developAttrs += String(format: " crs:Dehaze=\"%+d\"", dehaze)
            }
            if let vib = metadata.vibrance {
                developAttrs += String(format: " crs:Vibrance=\"%+d\"", vib)
            }
            if let sat = metadata.saturation {
                developAttrs += String(format: " crs:Saturation=\"%+d\"", sat)
            }
            if metadata.hasCrop {
                developAttrs += " crs:HasCrop=\"true\""
                if let top = metadata.cropTop {
                    developAttrs += String(format: " crs:CropTop=\"%.6f\"", top)
                }
                if let left = metadata.cropLeft {
                    developAttrs += String(format: " crs:CropLeft=\"%.6f\"", left)
                }
                if let bottom = metadata.cropBottom {
                    developAttrs += String(format: " crs:CropBottom=\"%.6f\"", bottom)
                }
                if let right = metadata.cropRight {
                    developAttrs += String(format: " crs:CropRight=\"%.6f\"", right)
                }
                if let angle = metadata.cropAngle, abs(angle) > 0.001 {
                    developAttrs += String(format: " crs:CropAngle=\"%.6f\"", angle)
                }
            }
            if metadata.convertToGrayscale == true {
                developAttrs += " crs:ConvertToGrayscale=\"True\""
            }
            if let profile = metadata.cameraProfile, !profile.isEmpty {
                developAttrs += " crs:CameraProfile=\"\(escapeXML(profile))\""
            }
        }
        
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"\(rawFileNameAttr)\(ratingAttr)\(labelAttr)\(flagAttr)\(developAttrs)>
        \(keywordsXML.isEmpty ? "" : keywordsXML + "\n")\(titleXML.isEmpty ? "" : titleXML + "\n")\(captionXML.isEmpty ? "" : captionXML + "\n")  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        
        return "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n\(xml)\n<?xpacket end=\"w\"?>"
    }
    
    private static func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
