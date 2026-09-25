import XCTest
import AppKit
import CoreImage
import CryptoKit
import ImageIO
@testable import LumiBase

/// Opt-in native-resolution ROI benchmark. Normal swift test runs skip it.
final class ROIBenchmarkTests: XCTestCase {
    private struct Manifest: Decodable { let images: [Sample] }
    private struct Sample: Decodable {
        let path: String
        let width: Int
        let height: Int
        let sidecars: [Sidecar]?
        let metadata: [String: JSONValue]?
    }
    private struct Sidecar: Decodable { let path: String }
    private enum JSONValue: Decodable {
        case string(String), number(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .string(try c.decode(String.self)) }
        }
    }
    private struct Source {
        let sample: Sample
        let sidecars: [String]
    }
    private struct Graph {
        let processed: CIImage
        let extent: CGRect
        let baseTemperature: Float
        let baseTint: Float
        let constructionMS: Double
    }
    private struct Materialized {
        let image: CGImage
        let bytes: Data
        let elapsedMS: Double
        let checksum: String
    }
    private struct ROI {
        let name: String
        let rect: CGRect
    }

    private let options: [CIContextOption: Any] = [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ]
    private let viewport = CGSize(width: 2400, height: 1600)
    private let repetitions = 2

    func testNativeFullVersusVisibleRegionBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LUMIBASE_ROI_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LUMIBASE_ROI_BENCHMARK=1, LUMIBASE_ROI_MANIFEST and LUMIBASE_ROI_OUTPUT to run")
        }
        let manifestURL = try XCTUnwrap(env["LUMIBASE_ROI_MANIFEST"].map(URL.init(fileURLWithPath:)))
        let outputURL = try XCTUnwrap(env["LUMIBASE_ROI_OUTPUT"].map(URL.init(fileURLWithPath:)))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))

        // Bound the sample to four real manifest files spanning four native sizes/cameras.
        let requested = Set(env["LUMIBASE_ROI_PATHS"]?.split(separator: "|").map(String.init) ?? [])
        let selected = manifest.images.filter { requested.contains($0.path) }
        XCTAssertEqual(selected.count, 4, "Select exactly four manifest files with varied dimensions")
        let sources = selected.map { Source(sample: $0, sidecars: ($0.sidecars ?? []).map(\.path)) }
        XCTAssertEqual(Set(sources.map { "\($0.sample.width)x\($0.sample.height)" }).count, 4,
                       "Selected sample must span four manifest dimensions")
        for source in sources {
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: source.sample.path), "Unreadable source: \(source.sample.path)")
            XCTAssertTrue(source.sample.path.hasPrefix("/Volumes/Extreme SSD/Working/"), "Unexpected source root")
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let paths = Array(Set(sources.flatMap { [$0.sample.path] + $0.sidecars })).sorted()
        let beforeHashes = try hashes(for: paths)
        let settings = syntheticSettings()
        let settingsDescription: [String: Any] = [
            "source": "explicit in-memory synthetic experiment values; not read from selected DNG metadata",
            "exposure2012": 0.35, "temperature": 6100, "tint": 8, "contrast2012": 12,
            "highlights2012": -18, "shadows2012": 22, "whites2012": 8, "blacks2012": -5,
            "vibrance": 14, "clarity2012": 8, "texture": 4
        ]
        let context = CIContext(options: options)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var records: [[String: Any]] = []
        var parityRecords: [[String: Any]] = []
        var sourceMetadata: [[String: Any]] = []

        // Decode and construct one complete processing graph per source, outside render timings.
        for (sourceIndex, source) in sources.enumerated() {
            let graph = try makeGraph(source: source, settings: settings)
            let rois = makeROIs(extent: graph.extent)
            let roiTraversal = sourceIndex.isMultiple(of: 2) ? rois : Array(rois.reversed())
            XCTAssertEqual(rois.count, 6)
            sourceMetadata.append([
                "path": source.sample.path,
                "manifest_dimensions": [source.sample.width, source.sample.height],
                "actual_processed_extent": rectJSON(graph.extent),
                "base_temperature": graph.baseTemperature,
                "base_tint": graph.baseTint,
                "decode_and_graph_construction_ms": graph.constructionMS,
                "raw_filter_options": ["exposure": 0.0, "baselineExposure": 0.30,
                                       "shadowBias": 0.0, "boostShadowAmount": 0.0,
                                       "boostAmount": 1.0, "highlightRecovery": "enabled on macOS 26+"],
                "manifest_metadata": source.sample.metadata.map(metadataJSON) ?? [:],
                "rois": rois.map { ["name": $0.name, "rect": rectJSON($0.rect)] }
            ])

            // Warm both paths once per ROI. Outputs are immediately released.
            for roi in roiTraversal {
                _ = try materialize(processed: graph.processed, rect: graph.extent, context: context, colorSpace: colorSpace)
                _ = try materialize(processed: graph.processed, rect: roi.rect, context: context, colorSpace: colorSpace)
            }

            for roi in roiTraversal {
                // Full output is materialized, cropped, compared, then released before the next ROI.
                let full = try materialize(processed: graph.processed, rect: graph.extent, context: context, colorSpace: colorSpace)
                let direct = try materialize(processed: graph.processed, rect: roi.rect, context: context, colorSpace: colorSpace)
                let cropCandidates: [(String, CGRect)] = [
                    ("cgimage-top-origin", cgCropRect(roi.rect, in: graph.extent, topOrigin: true)),
                    ("ci-bottom-origin", cgCropRect(roi.rect, in: graph.extent, topOrigin: false))
                ]
                var best: (name: String, image: CGImage, bytes: Data, elapsed: Double,
                           diff: (maxDiff: Int, meanDiff: Double, mismatches: Int, count: Int))?
                var candidateDiagnostics: [[String: Any]] = []
                for (name, cropRect) in cropCandidates {
                    let cropStart = now()
                    let candidateImage = try XCTUnwrap(full.image.cropping(to: cropRect), "CGImage crop failed")
                    let candidateBytes = try pixelBytes(candidateImage)
                    let cropMS = elapsed(since: cropStart)
                    let diff = compare(direct.bytes, width: direct.image.width, height: direct.image.height,
                                       against: candidateBytes, width: candidateImage.width, height: candidateImage.height)
                    candidateDiagnostics.append(["mapping": name, "max_channel_diff": diff.maxDiff,
                                                 "mean_channel_diff": diff.meanDiff,
                                                 "mismatched_channel_count": diff.mismatches,
                                                 "crop_copy_ms": cropMS])
                    // CGImage uses top-origin image coordinates; preserve that geometric mapping.
                    // The bottom-origin candidate is retained only as a diagnostic.
                    if best == nil {
                        best = (name, candidateImage, candidateBytes, cropMS, diff)
                    }
                }
                let chosen = try XCTUnwrap(best)
                let comparison = chosen.diff
                parityRecords.append([
                    "path": source.sample.path, "roi": roi.name,
                    "roi_dimensions": [direct.image.width, direct.image.height],
                    "cropped_dimensions": [chosen.image.width, chosen.image.height],
                    "crop_coordinate_mapping": chosen.name,
                    "crop_mapping_diagnostics": candidateDiagnostics,
                    "roi_sha256": direct.checksum, "cropped_sha256": sha256(chosen.bytes),
                    "max_channel_diff": comparison.maxDiff,
                    "mean_channel_diff": comparison.meanDiff,
                    "mismatched_channel_count": comparison.mismatches,
                    "compared_channel_count": comparison.count,
                    "exactly_equal": comparison.mismatches == 0 && direct.image.width == chosen.image.width && direct.image.height == chosen.image.height,
                    "crop_copy_ms": chosen.elapsed
                ])

                let abba = ["full", "roi", "roi", "full"]
                for trial in 0..<(repetitions * 2) {
                    // Alternate ROI traversal direction between ROIs/sources to limit order bias.
                    let condition = abba[trial]
                    let rect = condition == "full" ? graph.extent : roi.rect
                    let observation = try materialize(processed: graph.processed, rect: rect, context: context, colorSpace: colorSpace)
                    records.append([
                        "path": source.sample.path, "roi": roi.name,
                        "roi_order": sourceIndex.isMultiple(of: 2) ? "manifest-order" : "reverse-order",
                        "trial": trial + 1, "condition": condition,
                        "matched_order": abba.joined(separator: ","),
                        "decode_and_graph_construction_ms": graph.constructionMS,
                        "forced_render_and_materialization_ms": observation.elapsedMS,
                        "checksum_outside_timed_region": observation.checksum,
                        "pixel_width": observation.image.width, "pixel_height": observation.image.height,
                        "crop_copy_reference_ms": condition == "full" ? chosen.elapsed : 0,
                        "total_ms": observation.elapsedMS + (condition == "full" ? chosen.elapsed : 0)
                    ])
                }
                _ = full
                _ = direct
            }
        }

        let afterHashes = try hashes(for: paths)
        let hashChecks = paths.map { path in
            ["path": path, "before_sha256": beforeHashes[path] ?? "missing",
             "after_sha256": afterHashes[path] ?? "missing",
             "unchanged": beforeHashes[path] == afterHashes[path]] as [String: Any]
        }
        XCTAssertTrue(hashChecks.allSatisfy { $0["unchanged"] as? Bool == true }, "Source or sidecar changed during benchmark")
        XCTAssertEqual(records.count, sources.count * 6 * repetitions * 2,
                       "Executed sample count must equal source × ROI × trial count")
        XCTAssertEqual(parityRecords.count, sources.count * 6)

        let summary = summarize(records, parity: parityRecords, sources: sources.count,
                                roiCount: 6, warmupCount: sources.count * 12)
        try writeJSON(["manifest": manifestURL.path, "context_options": ["useSoftwareRenderer": false, "highQualityDownsample": true],
                       "output_format": "RGBA8 sRGB", "viewport_native_pixels": [Int(viewport.width), Int(viewport.height)],
                       "synthetic_settings": settingsDescription, "source_metadata": sourceMetadata,
                       "memory_measurement": "unavailable: no condition-isolated /usr/bin/time -l run",
                       "records": records, "parity": parityRecords, "input_hashes": hashChecks],
                      to: outputURL.appendingPathComponent("raw-results.json"))
        try writeJSON(summary, to: outputURL.appendingPathComponent("summary.json"))
        try writeCSV(records, to: outputURL.appendingPathComponent("raw-results.csv"))
        try writeCSV(parityRecords, to: outputURL.appendingPathComponent("parity.csv"))
        XCTAssertTrue(parityRecords.allSatisfy { $0["exactly_equal"] as? Bool == true },
                      "ROI output differs from crop of full processed output; inspect parity.csv")
    }

    private func syntheticSettings() -> XMPMetadata {
        XMPMetadata(exposure2012: 0.35, temperature: 6100, tint: 8, contrast2012: 12,
                    highlights2012: -18, shadows2012: 22, whites2012: 8, blacks2012: -5,
                    vibrance: 14, clarity2012: 8, texture: 4)
    }

    private func makeGraph(source: Source, settings: XMPMetadata) throws -> Graph {
        try autoreleasepool {
            let start = now()
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: URL(fileURLWithPath: source.sample.path)))
            let defaultTemperature = raw.neutralTemperature
            let defaultTint = raw.neutralTint
            raw.exposure = 0
            let baseTemperature: Float
            if let temperature = settings.temperature, temperature > 0 {
                raw.neutralTemperature = Float(temperature)
                baseTemperature = Float(temperature)
            } else {
                baseTemperature = defaultTemperature
            }
            let baseTint: Float
            if let tint = settings.tint {
                let temperatureDelta = Double(baseTemperature - defaultTemperature)
                raw.neutralTint = Float(tint) + Float(temperatureDelta * 0.012)
                baseTint = Float(tint)
            } else {
                baseTint = defaultTint
            }
            raw.baselineExposure = 0.30
            raw.shadowBias = 0
            raw.boostShadowAmount = 0
            raw.boostAmount = 1
            if #available(macOS 26.0, *) { raw.isHighlightRecoveryEnabled = true }
            let base = try XCTUnwrap(raw.outputImage, "CIRAWFilter produced no image")
            let holder = BaseImageHolder(full: base, display: base, interactive: base,
                                         fullExtent: base.extent, displayExtent: base.extent,
                                         interactiveExtent: base.extent,
                                         baseTemperature: baseTemperature, baseTint: baseTint,
                                         baseExposure: 0, isRaw: true, supportsNativeInspection: true)
            let processed = AdobeColorPipeline.shared.process(image: base, cameraModel: nil,
                                                               xmp: settings, baseHolder: holder)
            return Graph(processed: processed, extent: processed.extent,
                         baseTemperature: baseTemperature, baseTint: baseTint,
                         constructionMS: elapsed(since: start))
        }
    }

    private func makeROIs(extent: CGRect) -> [ROI] {
        let width = min(viewport.width, extent.width)
        let height = min(viewport.height, extent.height)
        let minX = extent.minX
        let maxX = extent.maxX - width
        let minY = extent.minY
        let maxY = extent.maxY - height
        let midX = ((minX + maxX) / 2).rounded(.down)
        let midY = ((minY + maxY) / 2).rounded(.down)
        return [
            ROI(name: "center", rect: CGRect(x: midX, y: midY, width: width, height: height)),
            ROI(name: "top-edge-mid", rect: CGRect(x: midX, y: maxY, width: width, height: height)),
            ROI(name: "top-left", rect: CGRect(x: minX, y: maxY, width: width, height: height)),
            ROI(name: "top-right", rect: CGRect(x: maxX, y: maxY, width: width, height: height)),
            ROI(name: "bottom-left", rect: CGRect(x: minX, y: minY, width: width, height: height)),
            ROI(name: "bottom-right", rect: CGRect(x: maxX, y: minY, width: width, height: height))
        ]
    }

    private func materialize(processed: CIImage, rect: CGRect, context: CIContext,
                             colorSpace: CGColorSpace) throws -> Materialized {
        try autoreleasepool {
            let start = now()
            let image = try XCTUnwrap(context.createCGImage(processed, from: rect, format: .RGBA8,
                                                             colorSpace: colorSpace, deferred: false))
            XCTAssertEqual(image.width, Int(rect.width), "Rendered width did not match requested CI extent")
            XCTAssertEqual(image.height, Int(rect.height), "Rendered height did not match requested CI extent")
            let bytes = try pixelBytes(image) // Read pixels before stopping the render timer.
            let time = elapsed(since: start)
            return Materialized(image: image, bytes: bytes, elapsedMS: time, checksum: sha256(bytes))
        }
    }

    private func pixelBytes(_ image: CGImage) throws -> Data {
        let backing = try XCTUnwrap(image.dataProvider?.data as Data?, "CGImage has no materialized pixel data")
        let bytesPerPixel = image.bitsPerPixel / 8
        XCTAssertEqual(bytesPerPixel, 4, "Expected RGBA8 pixels")
        let packedRowBytes = image.width * bytesPerPixel
        XCTAssertGreaterThanOrEqual(image.bytesPerRow, packedRowBytes)
        let requiredBytes = image.height == 0 ? 0 : (image.height - 1) * image.bytesPerRow + packedRowBytes
        XCTAssertGreaterThanOrEqual(backing.count, requiredBytes)
        var packed = Data(capacity: packedRowBytes * image.height)
        backing.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<image.height {
                packed.append(base.advanced(by: row * image.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                              count: packedRowBytes)
            }
        }
        return packed
    }

    private func cgCropRect(_ roi: CGRect, in fullExtent: CGRect, topOrigin: Bool) -> CGRect {
        CGRect(x: roi.minX - fullExtent.minX,
               y: topOrigin ? fullExtent.maxY - roi.maxY : roi.minY - fullExtent.minY,
               width: roi.width, height: roi.height).integral
    }

    private func compare(_ a: Data, width aw: Int, height ah: Int,
                         against b: Data, width bw: Int, height bh: Int) -> (maxDiff: Int, meanDiff: Double, mismatches: Int, count: Int) {
        guard aw == bw, ah == bh else { return (255, 255, max(aw * ah, bw * bh) * 4, min(aw * ah, bw * bh) * 4) }
        let count = min(a.count, b.count)
        var maximum = 0
        var sum: UInt64 = 0
        var mismatches = 0
        for index in 0..<count {
            let delta = abs(Int(a[index]) - Int(b[index]))
            maximum = max(maximum, delta)
            sum += UInt64(delta)
            if delta != 0 { mismatches += 1 }
        }
        return (maximum, count == 0 ? 0 : Double(sum) / Double(count), mismatches, count)
    }

    private func metadataJSON(_ metadata: [String: JSONValue]) -> [String: Any] {
        metadata.mapValues { value in
            switch value {
            case .string(let s): return s
            case .number(let n): return n
            case .bool(let b): return b
            case .null: return NSNull()
            }
        }
    }
    private func rectJSON(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
    private func hashes(for paths: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            result[path] = sha256(try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
        }
        return result
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func elapsed(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(p * Double(sorted.count))) - 1))]
    }
    private func summarize(_ records: [[String: Any]], parity: [[String: Any]],
                           sources: Int, roiCount: Int, warmupCount: Int) -> [String: Any] {
        var metrics: [[String: Any]] = []
        for condition in ["full", "roi"] {
            let selected = records.filter { $0["condition"] as? String == condition }
            for key in ["forced_render_and_materialization_ms", "total_ms"] {
                let values = selected.compactMap { $0[key] as? Double }
                metrics.append(["condition": condition, "metric": key, "count": values.count,
                                "median_ms": percentile(values, 0.5) ?? 0,
                                "p95_ms": percentile(values, 0.95) ?? 0])
            }
        }
        let groups = Set(records.compactMap { row -> String? in
            guard let path = row["path"] as? String, let roi = row["roi"] as? String,
                  let condition = row["condition"] as? String else { return nil }
            return "\(path)|\(roi)|\(condition)"
        })
        var bySourceROI: [[String: Any]] = []
        for group in groups.sorted() {
            let selected = records.filter { "\($0["path"] as? String ?? "")|\($0["roi"] as? String ?? "")|\($0["condition"] as? String ?? "")" == group }
            for key in ["forced_render_and_materialization_ms", "total_ms"] {
                let values = selected.compactMap { $0[key] as? Double }
                bySourceROI.append(["group": group, "metric": key, "count": values.count,
                                    "median_ms": percentile(values, 0.5) ?? 0,
                                    "p95_ms": percentile(values, 0.95) ?? 0])
            }
        }
        let cropValues = parity.compactMap { $0["crop_copy_ms"] as? Double }
        let allParity = parity.compactMap { $0["max_channel_diff"] as? Int }
        return ["source_count": sources, "rois_per_source": roiCount, "warmup_render_count": warmupCount,
                "measured_render_count": records.count, "expected_measured_render_count": sources * roiCount * repetitions * 2,
                "parity_case_count": parity.count, "parity_exact_count": parity.filter { $0["exactly_equal"] as? Bool == true }.count,
                "max_channel_diff_across_cases": allParity.max() ?? 0,
                "metrics": metrics, "per_source_roi_metrics": bySourceROI,
                "crop_copy_cost_ms": ["count": cropValues.count,
                                      "median": percentile(cropValues, 0.5) ?? 0,
                                      "p95": percentile(cropValues, 0.95) ?? 0],
                "decode_and_graph_construction_ms": "one decode + pipeline graph construction per source; values are in source_metadata and repeated raster timings",
                "memory_measurement": "unavailable: no condition-isolated /usr/bin/time -l run",
                "os_cache": "warmup performed; no cold OS-cache claim"]
    }
    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
    private func writeCSV(_ rows: [[String: Any]], to url: URL) throws {
        guard let first = rows.first else { return }
        let fields = first.keys.sorted()
        var lines = [fields.joined(separator: ",")]
        for row in rows {
            lines.append(fields.map { field in
                let value = String(describing: row[field] ?? "")
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }.joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
