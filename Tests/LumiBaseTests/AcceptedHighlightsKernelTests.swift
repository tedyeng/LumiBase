import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class AcceptedHighlightsKernelTests: XCTestCase {
    private let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private lazy var context = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAf,
                                                  .workingColorSpace: linearSRGB, .outputColorSpace: linearSRGB])

    func testNeutralEndpointsPrepareExpectedQuarterGridAndPreserveExtent() throws {
        let extent = CGRect(x: 0, y: 0, width: 80, height: 52)
        let baseline = solidImage(extent: extent, color: [0.32, 0.32, 0.32])
        let target = solidImage(extent: extent, color: [0.32, 0.32, 0.32])

        let field = try AcceptedHighlightsKernel.prepare(baseline: baseline, target: target, context: context)
        XCTAssertEqual(field.quarterWidth, 20)
        XCTAssertEqual(field.quarterHeight, 13)
        XCTAssertEqual(field.extent, extent)

        let result = AcceptedHighlightsKernel.apply(baseline: baseline, target: target, field: field)
        XCTAssertEqual(result.extent, extent)
    }

    func testPreparedFieldRetainsFullExtentForCroppedROI() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 96)
        let baseline = solidImage(extent: extent, color: [0.45, 0.38, 0.24])
        let target = solidImage(extent: extent, color: [0.19, 0.16, 0.10])
        let field = try AcceptedHighlightsKernel.prepare(baseline: baseline, target: target, context: context)
        let full = AcceptedHighlightsKernel.apply(baseline: baseline, target: target, field: field)
        let roi = CGRect(x: 19, y: 13, width: 71, height: 53)

        XCTAssertEqual(field.quarterWidth, 32)
        XCTAssertEqual(field.quarterHeight, 24)
        XCTAssertEqual(full.extent, extent)
        XCTAssertEqual(full.cropped(to: roi).extent, roi)
        XCTAssertEqual(AcceptedHighlightsKernel.apply(baseline: baseline, target: target, field: field)
            .cropped(to: roi).extent, roi)
    }

    func testFieldTranslationAndActualROIPixels() throws {
        let extent = CGRect(x: 0, y: 0, width: 129, height: 97)
        let b = solidImage(extent: extent, color: [0.45, 0.38, 0.24])
        let t = solidImage(extent: extent, color: [0.19, 0.16, 0.10])
        let field = try AcceptedHighlightsKernel.prepare(baseline: b, target: t, context: context)
        let original = AcceptedHighlightsKernel.apply(baseline: b, target: t, field: field)
        let translation = CGAffineTransform(translationX: 13, y: 17)
        let shiftedB = b.transformed(by: translation), shiftedT = t.transformed(by: translation)
        let shiftedField = try AcceptedHighlightsKernel.prepare(baseline: shiftedB, target: shiftedT, context: context)
        let shifted = AcceptedHighlightsKernel.apply(baseline: shiftedB, target: shiftedT, field: shiftedField)
        func pixels(_ image: CIImage, _ bounds: CGRect) -> [Float] {
            var values = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
            context.render(image, toBitmap: &values, rowBytes: Int(bounds.width) * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: linearSRGB)
            return values
        }
        let first = pixels(original, extent), moved = pixels(shifted, shifted.extent)
        XCTAssertLessThan(zip(first, moved).map { abs($0 - $1) }.max() ?? .infinity, 0.00001)
        let roi = CGRect(x: 19, y: 13, width: 71, height: 53)
        let cropped = pixels(original, roi)
        var error: Float = 0
        for y in 0..<53 { for x in 0..<71 { for c in 0..<3 {
            error = max(error, abs(cropped[(y * 71 + x) * 4 + c] - first[((y + 97 - 66) * 129 + x + 19) * 4 + c]))
        } } }
        XCTAssertLessThan(error, 0.00001)
    }

    func testScratchActualEndpointParityHarness() throws {
        guard let baselinePath = ProcessInfo.processInfo.environment["HIGHLIGHTS_BASELINE_TIFF"],
              let targetPath = ProcessInfo.processInfo.environment["HIGHLIGHTS_TARGET_TIFF"],
              let outputPath = ProcessInfo.processInfo.environment["HIGHLIGHTS_NATIVE_RAW"] else {
            throw XCTSkip("Scratch actual endpoint parity harness is opt-in")
        }
        let baseline = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: baselinePath)))
        let target = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: targetPath)))
        if let endpointPath = ProcessInfo.processInfo.environment["HIGHLIGHTS_ENDPOINT_RAW"] {
            FileManager.default.createFile(atPath: endpointPath, contents: nil)
            let endpointFile = try FileHandle(forWritingTo: URL(fileURLWithPath: endpointPath))
            defer { try? endpointFile.close() }
            let width = Int(baseline.extent.width), height = Int(baseline.extent.height), bandHeight = 96
            var pixels = [Float](repeating: 0, count: width * bandHeight * 4)
            for y in stride(from: 0, to: height, by: bandHeight) {
                let rows = min(bandHeight, height-y)
                pixels.withUnsafeMutableBytes { bytes in
                    context.render(baseline, toBitmap: bytes.baseAddress!, rowBytes: width*16,
                        bounds: CGRect(x: baseline.extent.minX, y: CGFloat(y), width: CGFloat(width), height: CGFloat(rows)),
                        format: .RGBAf, colorSpace: linearSRGB)
                }
                try endpointFile.write(contentsOf: Data(bytes: pixels, count: width*rows*16))
            }
        }
        let field = try AcceptedHighlightsKernel.prepare(baseline: baseline, target: target, context: context)
        let output = AcceptedHighlightsKernel.apply(baseline: baseline, target: target, field: field)
        let width = Int(output.extent.width), height = Int(output.extent.height), bandHeight = 96
        if let fieldPath = ProcessInfo.processInfo.environment["HIGHLIGHTS_FIELD_RAW"] {
            FileManager.default.createFile(atPath: fieldPath, contents: nil)
            let fieldFile = try FileHandle(forWritingTo: URL(fileURLWithPath: fieldPath))
            defer { try? fieldFile.close() }
            var fieldBand = [Float](repeating: 0, count: width * min(bandHeight, height) * 4)
            for y in stride(from: 0, to: height, by: bandHeight) {
                let rows = min(bandHeight, height - y)
                fieldBand.withUnsafeMutableBytes { bytes in
                    context.render(field.correctionImage, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                                   bounds: CGRect(x: output.extent.minX, y: CGFloat(y), width: CGFloat(width), height: CGFloat(rows)),
                                   format: .RGBAf, colorSpace: linearSRGB)
                }
                try fieldFile.write(contentsOf: Data(bytes: fieldBand, count: width * rows * 16))
            }
        }
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        defer { try? file.close() }
        var band = [Float](repeating: 0, count: width * min(bandHeight, height) * 4)
        for y in stride(from: 0, to: height, by: bandHeight) {
            let rows = min(bandHeight, height - y)
            band.withUnsafeMutableBytes { bytes in
                context.render(output, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                               bounds: CGRect(x: output.extent.minX, y: CGFloat(y), width: CGFloat(width), height: CGFloat(rows)),
                               format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
            }
            try file.write(contentsOf: Data(bytes: band, count: width * rows * 16))
        }
        print("native endpoint extent=\(output.extent) low=\(field.quarterWidth)x\(field.quarterHeight)")
    }

    private func solidImage(extent: CGRect, color: [Float]) -> CIImage {
        let width = Int(extent.width), height = Int(extent.height)
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: linearSRGB,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let components = [CGFloat(color[0]), CGFloat(color[1]), CGFloat(color[2]), 1]
        let cgColor = CGColor(colorSpace: linearSRGB, components: components)!
        bitmap.setFillColor(cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CIImage(cgImage: bitmap.makeImage()!)
    }
}
