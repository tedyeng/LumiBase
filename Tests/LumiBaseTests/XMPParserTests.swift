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
    
    func testDevelopBasicRoundTrip() {
        var develop = XMPMetadata()
        develop.exposure2012 = 0.35
        develop.temperature = 6200
        develop.tint = 8
        develop.contrast2012 = 12
        develop.highlights2012 = -75
        develop.shadows2012 = 45
        develop.whites2012 = -20
        develop.blacks2012 = -15
        develop.texture = 8
        develop.clarity2012 = 2
        develop.dehaze = 12
        develop.vibrance = 10
        develop.saturation = 10
        develop.cameraProfile = "Adobe Standard"
        develop.convertToGrayscale = true
        
        XCTAssertTrue(develop.hasDevelopEdits)
        
        let xml = XMPWriter.generateXMPXML(metadata: develop)
        let parsed = XMPParser.parse(data: xml.data(using: .utf8)!)
        
        XCTAssertEqual(parsed.exposure2012, 0.35)
        XCTAssertEqual(parsed.temperature, 6200)
        XCTAssertEqual(parsed.tint, 8)
        XCTAssertEqual(parsed.contrast2012, 12)
        XCTAssertEqual(parsed.highlights2012, -75)
        XCTAssertEqual(parsed.shadows2012, 45)
        XCTAssertEqual(parsed.whites2012, -20)
        XCTAssertEqual(parsed.blacks2012, -15)
        XCTAssertEqual(parsed.texture, 8)
        XCTAssertEqual(parsed.clarity2012, 2)
        XCTAssertEqual(parsed.dehaze, 12)
        XCTAssertEqual(parsed.vibrance, 10)
        XCTAssertEqual(parsed.saturation, 10)
        XCTAssertEqual(parsed.cameraProfile, "Adobe Standard")
        XCTAssertEqual(parsed.convertToGrayscale, true)
        
        var resetTarget = parsed
        resetTarget.resetDevelopSettings()
        XCTAssertFalse(resetTarget.hasDevelopEdits)
        XCTAssertNil(resetTarget.exposure2012)
        XCTAssertNil(resetTarget.temperature)
        XCTAssertNil(resetTarget.convertToGrayscale)
    }
}
