import XCTest
@testable import LumiBase

final class HighlightsParallelBoxTests: XCTestCase {
    func testPairedQuarterFieldTiming() throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_BOX_PAIRED"] == "1" else { throw XCTSkip("opt-in paired CPU benchmark") }
        let w = 2048, h = 1366
        let input = (0..<(w * h)).map { Float(($0 * 43) % 1009) / 1009 }
        var rows: [[String: Any]] = []
        for trial in 0..<8 {
            for mode in (trial % 2 == 0 ? ["serial", "parallel"] : ["parallel", "serial"]) {
                let start = ProcessInfo.processInfo.systemUptime
                let output = mode == "serial" ? serialBoxMean(input, width: w, height: h) : AcceptedHighlightsKernel.boxMeanParallel(input, width: w, height: h)
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                rows.append(["trial": trial, "mode": mode, "ms": ms, "checksum": output.reduce(0, +)])
                print("BOX_PAIRED trial=\(trial) mode=\(mode) ms=\(ms)")
            }
        }
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["LUMIBASE_BOX_PAIRED_RESULTS"])
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

    func testParallelBoxPreservesSerialReflectArithmetic() {
        for (w, h) in [(1, 1), (1, 113), (2, 3), (97, 96), (263, 199), (2048, 1366)] {
            let input = (0..<(w * h)).map { Float(($0 * 43) % 1009) / 1009 }
            let original = serialBoxMean(input, width: w, height: h)
            let parallel = AcceptedHighlightsKernel.boxMeanParallel(input, width: w, height: h)
            XCTAssertEqual(parallel, original, "Each Float must be unchanged for \(w)x\(h)")
        }
    }

    // Preserved sequential arithmetic from 1.7.1; independent reference in test target.
    private func serialBoxMean(_ input: [Float], width: Int, height: Int) -> [Float] {
        let radius = 48, divisor: Float = 97
        func reflect(_ index: Int, _ count: Int) -> Int {
            guard count > 1 else { return 0 }
            let period = count * 2
            let folded = ((index % period) + period) % period
            return folded < count ? folded : period - folded - 1
        }
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for offset in -radius...radius { sum += input[row + reflect(offset, width)] }
            for x in 0..<width {
                horizontal[row + x] = sum / divisor
                sum += input[row + reflect(x + radius + 1, width)]
                sum -= input[row + reflect(x - radius, width)]
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var sum: Float = 0
            for offset in -radius...radius { sum += horizontal[reflect(offset, height) * width + x] }
            for y in 0..<height {
                output[y * width + x] = sum / divisor
                sum += horizontal[reflect(y + radius + 1, height) * width + x]
                sum -= horizontal[reflect(y - radius, height) * width + x]
            }
        }
        return output
    }
}
