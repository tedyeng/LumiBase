import XCTest
import AppKit
import CoreImage
import CryptoKit
@testable import LumiBase

/// Opt-in integration benchmark; normal test runs skip it. Reads only the manifest's image and sidecar paths.
final class ContextBenchmarkTests: XCTestCase {
    private struct Manifest: Decodable { let images: [Sample] }
    private struct Sample: Decodable {
        let path: String
        let sidecars: [Sidecar]?
    }
    private struct Sidecar: Decodable { let path: String }
    private struct Input { let path: String; let sidecars: [String] }
    private struct Observation {
        let image: CGImage
        let constructionMS: Double
        let rasterMS: Double
        let totalMS: Double
        let checksum: String
    }

    func testContextLifetimeBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LUMIBASE_CONTEXT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LUMIBASE_CONTEXT_BENCHMARK=1, LUMIBASE_CONTEXT_MANIFEST and LUMIBASE_CONTEXT_OUTPUT to run")
        }
        let manifestURL = try XCTUnwrap(env["LUMIBASE_CONTEXT_MANIFEST"].map(URL.init(fileURLWithPath:)))
        let outputURL = try XCTUnwrap(env["LUMIBASE_CONTEXT_OUTPUT"].map(URL.init(fileURLWithPath:)))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let inputs = manifest.images.map { Input(path: $0.path, sidecars: ($0.sidecars ?? []).map(\.path)) }
        XCTAssertFalse(inputs.isEmpty)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let allPaths = Array(Set(inputs.flatMap { [$0.path] + $0.sidecars })).sorted()
        let beforeHashes = try hashes(for: allPaths)
        let xmp = XMPMetadata(exposure2012: 0.35, temperature: 6100, tint: 8,
                              contrast2012: 12, highlights2012: -18, shadows2012: 22,
                              whites2012: 8, blacks2012: -5, vibrance: 14,
                              clarity2012: 8, texture: 4)
        XCTAssertTrue(xmp.hasDevelopEdits)
        let outputs = [1600, 400]
        let options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        let setupStart = now()
        let reusedContext = CIContext(options: options)
        let reuseSetupMS = elapsed(since: setupStart)
        let sizes = inputs.flatMap { input in outputs.map { (input, $0) } }

        // One unrecorded warm-up of both variants over each sample and output size.
        for (input, maxPixel) in sizes {
            _ = try render(input, maxPixel: maxPixel, xmp: xmp, context: nil, options: options)
            _ = try render(input, maxPixel: maxPixel, xmp: xmp, context: reusedContext, options: options)
        }

        var records: [[String: Any]] = []
        var checksums: [String: String] = [:]
        var dimensions: [String: [Int]] = [:]
        let order = ["fresh", "reuse", "reuse", "fresh"] // matched ABBA repetitions, per image and size
        for (input, maxPixel) in sizes {
            for (trial, condition) in order.enumerated() {
                let context = condition == "reuse" ? reusedContext : nil
                let observation = try render(input, maxPixel: maxPixel, xmp: xmp, context: context, options: options)
                let key = "\(input.path)|\(maxPixel)"
                let currentDimensions = [observation.image.width, observation.image.height]
                if let prior = checksums[key] {
                    XCTAssertEqual(observation.checksum, prior, "Raster checksum mismatch: \(input.path) at \(maxPixel)")
                    XCTAssertEqual(currentDimensions, dimensions[key], "Raster dimensions changed: \(input.path) at \(maxPixel)")
                } else {
                    checksums[key] = observation.checksum
                    dimensions[key] = currentDimensions
                }
                records.append([
                    "path": input.path, "max_pixel_size": maxPixel,
                    "trial": trial + 1, "condition": condition,
                    "order": order.joined(separator: ","),
                    "context_construction_ms": observation.constructionMS,
                    "forced_cgimage_raster_ms": observation.rasterMS,
                    "thumbnail_pipeline_ms": observation.totalMS,
                    "pixel_width": observation.image.width,
                    "pixel_height": observation.image.height,
                    "sha256_cgimage_data": observation.checksum
                ])
            }
        }

        let afterHashes = try hashes(for: allPaths)
        let hashChecks = allPaths.map { path in
            ["path": path, "before_sha256": beforeHashes[path] ?? "missing",
             "after_sha256": afterHashes[path] ?? "missing",
             "unchanged": beforeHashes[path] == afterHashes[path]] as [String: Any]
        }
        XCTAssertTrue(hashChecks.allSatisfy { $0["unchanged"] as? Bool == true }, "Input/sidecar hash changed during benchmark")

        let summary = summarize(records, reuseSetupMS: reuseSetupMS, sampleCount: inputs.count,
                                imageSizePairs: sizes.count, warmupCount: sizes.count * 2)
        try writeJSON(["manifest": manifestURL.absoluteString, "synthetic_xmp": [
            "exposure2012": 0.35, "temperature": 6100, "tint": 8, "contrast2012": 12,
            "highlights2012": -18, "shadows2012": 22, "whites2012": 8, "blacks2012": -5,
            "vibrance": 14, "clarity2012": 8, "texture": 4
        ], "records": records, "input_hashes": hashChecks], to: outputURL.appendingPathComponent("raw-results.json"))
        try writeJSON(summary, to: outputURL.appendingPathComponent("summary.json"))
        try writeCSV(records, to: outputURL.appendingPathComponent("raw-results.csv"))
        XCTAssertEqual(records.count, sizes.count * order.count)
    }

    private func render(_ input: Input, maxPixel: Int, xmp: XMPMetadata,
                        context: CIContext?, options: [CIContextOption: Any]) throws -> Observation {
        try autoreleasepool {
            let totalStart = now()
            let rawFilter = try XCTUnwrap(CIRAWFilter(imageURL: URL(fileURLWithPath: input.path)))
            let base = try XCTUnwrap(rawFilter.outputImage, "CIRAWFilter produced no image: \(input.path)")
            let processed = AdobeColorPipeline.shared.process(image: base, cameraModel: nil, xmp: xmp)
            let extent = processed.extent
            let maxDimension = max(extent.width, extent.height)
            let scale = maxDimension > CGFloat(maxPixel) ? CGFloat(maxPixel) / maxDimension : 1
            let scaled = scale < 1 ? processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : processed
            let renderContext: CIContext
            let constructionMS: Double
            if let context {
                renderContext = context
                constructionMS = 0
            } else {
                let start = now()
                renderContext = CIContext(options: options)
                constructionMS = elapsed(since: start)
            }
            let rasterStart = now()
            let cgImage = try XCTUnwrap(renderContext.createCGImage(scaled, from: scaled.extent), "CIContext raster failed: \(input.path)")
            let rasterMS = elapsed(since: rasterStart)
            _ = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let bytes = try XCTUnwrap(cgImage.dataProvider?.data) as Data
            let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return Observation(image: cgImage, constructionMS: constructionMS,
                               rasterMS: rasterMS, totalMS: elapsed(since: totalStart), checksum: checksum)
        }
    }

    private func hashes(for paths: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            result[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func elapsed(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
    private func writeJSON(_ object: Any, to url: URL) throws {
        let invalid = invalidJSONValues(object, path: "$", collected: [])
        guard invalid.isEmpty else {
            XCTFail("Non-JSON values for \(url.lastPathComponent): \(invalid.joined(separator: ", "))")
            return
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
    private func invalidJSONValues(_ value: Any, path: String, collected: [String]) -> [String] {
        if value is NSNull || value is String || value is NSNumber { return collected }
        if let dict = value as? [String: Any] {
            return dict.reduce(collected) { invalid, pair in
                invalidJSONValues(pair.value, path: "\(path).\(pair.key)", collected: invalid)
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().reduce(collected) { invalid, pair in
                invalidJSONValues(pair.element, path: "\(path)[\(pair.offset)]", collected: invalid)
            }
        }
        return collected + ["\(path):\(String(reflecting: type(of: value)))"]
    }
    private func writeCSV(_ rows: [[String: Any]], to url: URL) throws {
        let fields = ["path", "max_pixel_size", "trial", "condition", "order", "context_construction_ms",
                      "forced_cgimage_raster_ms", "thumbnail_pipeline_ms", "pixel_width", "pixel_height", "sha256_cgimage_data"]
        var lines = [fields.joined(separator: ",")]
        for row in rows {
            lines.append(fields.map { field in
                let value = String(describing: row[field] ?? "")
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }.joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(p * Double(sorted.count))) - 1))]
    }
    private func summarize(_ records: [[String: Any]], reuseSetupMS: Double, sampleCount: Int,
                           imageSizePairs: Int, warmupCount: Int) -> [String: Any] {
        var metrics: [[String: Any]] = []
        for condition in ["fresh", "reuse"] {
            let selected = records.filter { $0["condition"] as? String == condition }
            for (key, name) in [("context_construction_ms", "context_construction"),
                                ("forced_cgimage_raster_ms", "forced_cgimage_raster"),
                                ("thumbnail_pipeline_ms", "thumbnail_pipeline")] {
                let values = selected.compactMap { $0[key] as? Double }
                metrics.append(["condition": condition, "metric": name, "count": values.count,
                                "median_ms": percentile(values, 0.5).map { $0 as Any } ?? NSNull(),
                                "p95_ms": percentile(values, 0.95).map { $0 as Any } ?? NSNull()])
            }
        }
        return ["sample_count": sampleCount, "image_size_pairs": imageSizePairs,
                "warmup_render_count": warmupCount, "measured_render_count": records.count,
                "matched_order": "fresh,reuse,reuse,fresh",
                "reuse_context_setup_ms_once": reuseSetupMS,
                "context_construction_in_reuse_per_render_ms": 0,
                "process_memory": "unavailable: the ABBA conditions run in one matched XCTest process; no condition-isolated /usr/bin/time -l RSS was collected",
                "metrics": metrics]
    }
}
