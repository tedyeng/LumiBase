import XCTest
@testable import LumiBase

final class XMPParserTests: XCTestCase {
    
    func testParseAdobeXMPStandard() {
        let sampleXMP = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmp:Rating="4"
            xmp:Label="Red"
            crs:Pick="1">
            <dc:subject>
             <rdf:Bag>
              <rdf:li>Landscape</rdf:li>
              <rdf:li>Tokyo</rdf:li>
              <rdf:li>Night</rdf:li>
             </rdf:Bag>
            </dc:subject>
            <dc:title>
             <rdf:Alt>
              <rdf:li xml:lang="x-default">Tokyo Tower at Night</rdf:li>
             </rdf:Alt>
            </dc:title>
            <dc:description>
             <rdf:Alt>
              <rdf:li xml:lang="x-default">Captured with 35mm lens from Roppongi Hills.</rdf:li>
             </rdf:Alt>
            </dc:description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        
        let data = sampleXMP.data(using: .utf8)!
        let metadata = XMPParser.parse(data: data)
        
        XCTAssertEqual(metadata.rating, 4)
        XCTAssertEqual(metadata.colorLabel, .red)
        XCTAssertEqual(metadata.flag, .pick)
        XCTAssertTrue(metadata.keywords.contains("Landscape"))
        XCTAssertTrue(metadata.keywords.contains("Tokyo"))
        XCTAssertTrue(metadata.keywords.contains("Night"))
        XCTAssertEqual(metadata.title, "Tokyo Tower at Night")
        XCTAssertEqual(metadata.caption, "Captured with 35mm lens from Roppongi Hills.")
    }
    
    func testXMPRoundTrip() {
        let original = XMPMetadata(
            rating: 5,
            colorLabel: .yellow,
            flag: .reject,
            keywords: ["Portrait", "Studio", "85mm"],
            title: "Studio Portrait #1",
            caption: "Key light at 45 degrees."
        )
        
        let generatedXML = XMPWriter.generateXMPXML(metadata: original, originalFilename: "DSC09999.ARW")
        let parsed = XMPParser.parse(data: generatedXML.data(using: .utf8)!)
        
        XCTAssertEqual(parsed.rating, 5)
        XCTAssertEqual(parsed.colorLabel, .yellow)
        XCTAssertEqual(parsed.flag, .reject)
        XCTAssertEqual(Set(parsed.keywords), Set(["Portrait", "Studio", "85mm"]))
        XCTAssertEqual(parsed.title, "Studio Portrait #1")
        XCTAssertEqual(parsed.caption, "Key light at 45 degrees.")
    }
    
    func testFilterCriteriaMatching() {
        let asset1 = PhotoAsset(
            fileURL: URL(fileURLWithPath: "/photos/DSC0001.ARW"),
            xmp: XMPMetadata(rating: 5, colorLabel: .red, flag: .pick, keywords: ["Landscape"])
        )
        
        let asset2 = PhotoAsset(
            fileURL: URL(fileURLWithPath: "/photos/IMG_1000.JPG"),
            xmp: XMPMetadata(rating: 2, colorLabel: .blue, flag: .unflagged, keywords: ["Street"])
        )
        
        var filter = FilterCriteria(minimumRating: 4)
        XCTAssertTrue(filter.matches(asset: asset1))
        XCTAssertFalse(filter.matches(asset: asset2))
        
        filter = FilterCriteria(selectedFlag: .pick)
        XCTAssertTrue(filter.matches(asset: asset1))
        XCTAssertFalse(filter.matches(asset: asset2))
        
        filter = FilterCriteria(selectedColorLabels: [.blue])
        XCTAssertFalse(filter.matches(asset: asset1))
        XCTAssertTrue(filter.matches(asset: asset2))
        
        filter = FilterCriteria(showRawOnly: true)
        XCTAssertTrue(filter.matches(asset: asset1))
        XCTAssertFalse(filter.matches(asset: asset2))
    }
    
    func testParseCameraRawDevelopSettings() {
        let xmpContent = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            crs:Exposure2012="+0.65"
            crs:Temperature="5600"
            crs:Tint="+10"
            crs:Contrast2012="+15"
            crs:Highlights2012="-20"
            crs:Shadows2012="+30"
            crs:HasCrop="True"
            crs:CameraProfile="Adobe Standard">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        
        let metadata = XMPParser.parse(data: xmpContent.data(using: .utf8)!)
        
        XCTAssertEqual(metadata.exposure2012, 0.65)
        XCTAssertEqual(metadata.temperature, 5600)
        XCTAssertEqual(metadata.tint, 10)
        XCTAssertEqual(metadata.contrast2012, 15)
        XCTAssertEqual(metadata.highlights2012, -20)
        XCTAssertEqual(metadata.shadows2012, 30)
        XCTAssertTrue(metadata.hasCrop)
        XCTAssertEqual(metadata.cameraProfile, "Adobe Standard")
        XCTAssertTrue(metadata.hasDevelopEdits)
    }
}
