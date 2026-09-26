import XCTest
import CoreImage
@testable import LumiBase

final class HighlightsSamplingTests: XCTestCase {
    func testGlobalPreparationReadsOnlyExactQuarterSamples() throws {
        for (width, height) in [(263, 197), (263, 198), (263, 199), (263, 200), (1, 1), (2, 3), (7, 5), (8, 8)] {
            let extent = CGRect(x: -21, y: 47, width: width, height: height)
            var pixels = [Float](repeating: 1, count: width * height * 4)
            for i in 0..<(width * height) {
                pixels[i * 4] = Float((i * 17) % 1009) / 1008
                pixels[i * 4 + 1] = Float((i * 23) % 997) / 996
                pixels[i * 4 + 2] = Float((i * 31) % 991) / 990
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let color = CGColorSpace(name: CGColorSpace.linearSRGB)!
            let baseline = CIImage(bitmapData: data, bytesPerRow: width * 16, size: extent.size, format: .RGBAf, colorSpace: color).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            let target = baseline.applyingFilter("CIExposureAdjust", parameters: ["inputEV": -2])
            let options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAf, .workingColorSpace: color]
            let reference = CIContext(options: options)
            let context = SamplingCountingContext(options: options)
            var expected: [[Float]] = []
            for image in [baseline, target] {
                var full = [Float](repeating: 0, count: width * height * 4)
                full.withUnsafeMutableBytes { reference.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: color) }
                var low: [Float] = []
                for y in stride(from: 0, to: height, by: 4) {
                    for x in stride(from: 0, to: width, by: 4) { low.append(contentsOf: full[((y * width + x) * 4)..<((y * width + x) * 4 + 4)]) }
                }
                expected.append(low)
            }
            _ = try AcceptedHighlightsKernel.prepare(baseline: baseline, target: target, context: context)
            let samples = ((width + 3) / 4) * ((height + 3) / 4)
            XCTAssertEqual(context.readPixels, 2 * samples, "no discarded full-resolution readback")
            XCTAssertEqual(context.outputs.count, 2)
            if context.outputs.count == 2 {
                for i in 0..<2 {
                    let errors = zip(context.outputs[i], expected[i]).map { abs($0 - $1) }
                    XCTAssertEqual(errors.max(), 0, "bit-exact globally phased top-left lattice, not averaged resize")
                }
            }
        }
    }
}
private final class SamplingCountingContext: CIContext, @unchecked Sendable {
    var readPixels = 0
    var outputs: [[Float]] = []
    override func render(_ image: CIImage, toBitmap data: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect, format: CIFormat, colorSpace: CGColorSpace?) {
        super.render(image, toBitmap: data, rowBytes: rowBytes, bounds: bounds, format: format, colorSpace: colorSpace)
        readPixels += Int(bounds.width * bounds.height)
        outputs.append(Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(bounds.width * bounds.height) * 4)))
    }
}
