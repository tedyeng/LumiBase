import XCTest
import AppKit
import CoreImage
@testable import LumiBase

/// Opt-in, read-only integration benchmark. Normal `swift test` runs skip this test.
final class SSDBenchmarkTests: XCTestCase {
    private struct Manifest: Decodable { let images: [SampleImage] }
    private struct SampleImage: Decodable {
        let path: String
        let format: String
        let width: Int
        let height: Int
        let sidecars: [Sidecar]
    }
    private struct Sidecar: Decodable { let path: String }

    func testRunOptInSSDBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_SSD_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LUMIBASE_SSD_BENCHMARK=1 and LUMIBASE_SSD_MANIFEST to run the SSD benchmark")
        }
        let env = ProcessInfo.processInfo.environment
        let manifestURL = try XCTUnwrap(env["LUMIBASE_SSD_MANIFEST"].map(URL.init(fileURLWithPath:)))
        let outputDir = try XCTUnwrap(env["LUMIBASE_SSD_OUTPUT"].map(URL.init(fileURLWithPath:)))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let imageRecords = manifest.images.map { sample -> (SampleImage, PhotoAsset, XMPMetadata) in
            let url = URL(fileURLWithPath: sample.path)
            var xmp = sample.sidecars.first.map { XMPParser.parse(url: URL(fileURLWithPath: $0.path)) } ?? .empty
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let asset = PhotoAsset(fileURL: url, fileSize: Int64(attrs?.fileSize ?? 0), dateModified: attrs?.contentModificationDate ?? .distantPast, xmp: xmp)
            xmp = asset.xmp
            return (sample, asset, xmp)
        }
        let assets = imageRecords.map(\.1)
        let preloader = PreviewPreloader(observeMemoryPressure: false)
        let thumbnailLoader = ThumbnailLoader.shared
        let rawLoader = RAWImageLoader.shared
        var results: [[String: Any]] = []
        var hardFailures: [String] = []

        // Measure ImageIO/CIRAWFilter lazy CIImage construction independently from a forced
        // native pixel render. Clear only the loader's in-memory holder between sample images.
        for (sample, asset, _) in imageRecords {
            rawLoader.clearCache()
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            let holder = await rawLoader.loadBaseHolder(from: asset.fileURL, xmp: asset.xmp)
            let decodeMS = elapsedMS(decodeStart)
            results.append(["kind": "base_ciimage_construction", "path": sample.path, "format": sample.format,
                            "milliseconds": decodeMS, "success": holder != nil,
                            "supports_native_inspection": holder?.supportsNativeInspection ?? false])
            guard let holder else { hardFailures.append("base decode failed: \(sample.path)"); continue }

            let renderStart = DispatchTime.now().uptimeNanoseconds
            let rendered = rawLoader.renderProcessed(baseHolder: holder, cameraModel: asset.cameraMetadata.model,
                                                       xmp: asset.xmp, fullResolution: true)
            let renderMS = elapsedMS(renderStart)
            let success = rendered != nil
            results.append(["kind": "forced_native_raster_completion", "path": sample.path, "format": sample.format,
                            "milliseconds": renderMS, "success": success,
                            "pixel_width": rendered.map { Int($0.size.width) } ?? 0,
                            "pixel_height": rendered.map { Int($0.size.height) } ?? 0])
            if !success { hardFailures.append("forced native raster completion failed or unsupported: \(sample.path)") }
        }

        // Edited RAW exclusions use parsed existing XMP. Sequences contain only safe assets for
        // speculative preview comparisons; decode failures above remain in the failure records.
        let eligible = imageRecords.filter { PreviewPreloader.isSafeToSpeculate($0.1) }.map(\.1)
        let excludedEditedRAW = imageRecords.filter { $0.1.isRaw && !$0.1.xmp.hasDevelopEdits }.count
        let editedRAWExcluded = imageRecords.filter { $0.1.isRaw && $0.1.xmp.hasDevelopEdits }.count
        let galleryIndices = Array(eligible.indices)
        let randomIndices = seededShuffle(galleryIndices, seed: 73421)
        let sequences: [(String, [Int])] = [
            ("sequential", galleryIndices),
            ("reversal", Array(galleryIndices.reversed())),
            ("random_seed_73421", randomIndices)
        ]
        let dwellMS = 150
        let outputPixelSize = 1600
        XCTAssertEqual(PreviewPreloader.previewSize, outputPixelSize)
        let randomNonNeighborTransitions = zip(randomIndices, randomIndices.dropFirst()).filter { abs($1 - $0) > 1 }.count
        XCTAssertEqual(Set(randomIndices), Set(galleryIndices), "Random navigation must be a permutation of the fixed gallery")
        XCTAssertGreaterThan(randomNonNeighborTransitions, 0, "Seeded random navigation must include actual non-neighbor targets")

        // Use original source paths and explicitly prime the existing foreground thumbnail cache.
        // This is a warm-cache comparison; it makes no cold SSD claim and never clears user cache.
        let cachePrimeStart = DispatchTime.now().uptimeNanoseconds
        var cachePrimeFailures: [String] = []
        for asset in eligible {
            if await thumbnailLoader.loadThumbnail(for: asset, maxPixelSize: outputPixelSize) == nil {
                cachePrimeFailures.append(asset.fileURL.path)
            }
        }
        let cachePrimeMS = elapsedMS(cachePrimeStart)
        if !cachePrimeFailures.isEmpty { hardFailures.append("foreground cache priming failed: \(cachePrimeFailures.joined(separator: ", "))") }
        let order = [false, true, true, false] // OFF/ON followed by ON/OFF, per sequence.
        for (sequenceName, navigationIndices) in sequences {
            guard navigationIndices.count > 1 else { continue }
            let navigationAssets = navigationIndices.map { eligible[$0] }
            for (trialIndex, preloadEnabled) in order.enumerated() {
                await preloader.cancelAndClear()
                let trialStart = DispatchTime.now().uptimeNanoseconds
                var preparationMS: [Double] = []
                var preloadReadyMS: [Double] = []
                var retrievalMS: [Double] = []
                var hits = 0, misses = 0, failures = 0
                var actualLastMoveDirection: PreviewTravelDirection = .stationary
                for step in 1..<navigationAssets.count {
                    let previous = navigationAssets[step - 1]
                    let next = navigationAssets[step]
                    let dwellStart = DispatchTime.now().uptimeNanoseconds
                    if preloadEnabled {
                        await preloader.update(assets: eligible, selectedID: previous.id, direction: actualLastMoveDirection)
                        preparationMS.append(elapsedMS(dwellStart))
                        var readyTime: Double?
                        while DispatchTime.now().uptimeNanoseconds - dwellStart < UInt64(dwellMS) * 1_000_000 {
                            if await preloader.cachedPreview(for: next) != nil {
                                readyTime = elapsedMS(dwellStart)
                                break
                            }
                            try await Task.sleep(nanoseconds: 5_000_000)
                        }
                        preloadReadyMS.append(readyTime ?? elapsedMS(dwellStart))
                    }
                    let dwellNanos = UInt64(dwellMS) * 1_000_000
                    let elapsedNanos = DispatchTime.now().uptimeNanoseconds - dwellStart
                    if elapsedNanos < dwellNanos { try await Task.sleep(nanoseconds: dwellNanos - elapsedNanos) }
                    let readStart = DispatchTime.now().uptimeNanoseconds
                    if preloadEnabled, await preloader.cachedPreview(for: next) != nil {
                        hits += 1
                    } else {
                        misses += 1
                        // Actual foreground production API on a speculative miss and every OFF read.
                        if await thumbnailLoader.loadThumbnail(for: next, maxPixelSize: outputPixelSize) == nil { failures += 1 }
                    }
                    retrievalMS.append(elapsedMS(readStart))
                    let galleryDelta = navigationIndices[step] - navigationIndices[step - 1]
                    actualLastMoveDirection = galleryDelta > 0 ? .forward : .backward
                }
                results.append(["kind": "preview_trial", "sequence": sequenceName,
                                "trial": trialIndex + 1, "preload": preloadEnabled ? "on" : "off",
                                "dwell_ms": dwellMS,
                                "thumbnail_max_pixel_size": outputPixelSize,
                                "foreground_cache_state": "warm_explicitly_primed",
                                "gallery_asset_paths": eligible.map { $0.fileURL.path },
                                "navigation_indices": navigationIndices,
                                "random_non_neighbor_transition_count": sequenceName == "random_seed_73421" ? randomNonNeighborTransitions : 0,
                                "preparation_ms": preparationMS, "preload_ready_ms": preloadReadyMS,
                                "retrieval_ms": retrievalMS, "hits": hits, "misses": misses,
                                "failures": failures, "elapsed_ms": elapsedMS(trialStart)])
                if failures > 0 { hardFailures.append("\(failures) foreground thumbnail failures in \(sequenceName) preload=\(preloadEnabled)") }
            }
        }
        await preloader.cancelAndClear()

        let previewTrials = results.filter { $0["kind"] as? String == "preview_trial" }
        XCTAssertTrue(previewTrials.allSatisfy { $0["thumbnail_max_pixel_size"] as? Int == outputPixelSize },
                      "ON and OFF must use the same 1600px output size")
        let allGalleryOrders = previewTrials.compactMap { $0["gallery_asset_paths"] as? [String] }
        XCTAssertEqual(Set(allGalleryOrders.map { $0.joined(separator: "\u{1f}") }).count, 1,
                         "Every traversal and preload arm must keep the same gallery asset order")
        for name in ["sequential", "reversal", "random_seed_73421"] {
            let selected = previewTrials.filter { $0["sequence"] as? String == name }
            XCTAssertEqual(Set(selected.compactMap { $0["gallery_asset_paths"] as? [String] }.map { $0.joined(separator: "\u{1f}") }).count, 1,
                               "All \(name) trials must use one constant gallery order")
        }

        let summary = makeSummary(results: results, sampleCount: assets.count,
                                  editedRAWExcluded: editedRAWExcluded,
                                  rawIncluded: excludedEditedRAW, dwellMS: dwellMS)
        var runSummary = summary
        runSummary["foreground_cache_state"] = "warm_explicitly_primed"
        runSummary["foreground_cache_prime_ms"] = cachePrimeMS
        runSummary["foreground_cache_prime_failures"] = cachePrimeFailures
        runSummary["thumbnail_max_pixel_size"] = outputPixelSize
        runSummary["gallery_order"] = eligible.map { $0.fileURL.path }
        runSummary["random_non_neighbor_transition_count"] = randomNonNeighborTransitions
        try writeJSON(["manifest": manifestURL.path, "results": results, "failures": hardFailures,
                       "foreground_cache_prime_ms": cachePrimeMS,
                       "foreground_cache_prime_failures": cachePrimeFailures], to: outputDir.appendingPathComponent("raw-results.json"))
        try writeJSON(runSummary, to: outputDir.appendingPathComponent("summary.json"))
        XCTAssertTrue(hardFailures.isEmpty, "Benchmark encountered decode/render failures; see raw-results.json: \(hardFailures.joined(separator: "; "))")
    }

    private func elapsedMS(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private func seededShuffle(_ input: [Int], seed: UInt64) -> [Int] {
        var values = input
        var state = seed
        if values.count > 1 {
            for i in stride(from: values.count - 1, through: 1, by: -1) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                values.swapAt(i, Int(state % UInt64(i + 1)))
            }
        }
        return values
    }
    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1)
        return sorted[max(0, index)]
    }
    private func makeSummary(results: [[String: Any]], sampleCount: Int, editedRAWExcluded: Int,
                             rawIncluded: Int, dwellMS: Int) -> [String: Any] {
        func values(_ kind: String) -> [Double] { results.filter { $0["kind"] as? String == kind }.compactMap { $0["milliseconds"] as? Double } }
        let preview = results.filter { $0["kind"] as? String == "preview_trial" }
        var trials: [[String: Any]] = []
        for name in ["sequential", "reversal", "random_seed_73421"] {
            for enabled in ["off", "on"] {
                let selected = preview.filter { $0["sequence"] as? String == name && $0["preload"] as? String == enabled }
                let reads = selected.flatMap { $0["retrieval_ms"] as? [Double] ?? [] }
                let prep = selected.flatMap { $0["preparation_ms"] as? [Double] ?? [] }
                let ready = selected.flatMap { $0["preload_ready_ms"] as? [Double] ?? [] }
                trials.append(["sequence": name, "preload": enabled, "trial_count": selected.count,
                               "retrieval_count": reads.count, "retrieval_median_ms": percentile(reads, 0.5) as Any? ?? NSNull(),
                               "retrieval_p95_ms": percentile(reads, 0.95) as Any? ?? NSNull(),
                               "preparation_median_ms": percentile(prep, 0.5) as Any? ?? NSNull(),
                               "preparation_p95_ms": percentile(prep, 0.95) as Any? ?? NSNull(),
                               "preload_ready_median_ms": percentile(ready, 0.5) as Any? ?? NSNull(),
                               "preload_ready_p95_ms": percentile(ready, 0.95) as Any? ?? NSNull(),
                               "hits": selected.compactMap { $0["hits"] as? Int }.reduce(0, +),
                               "misses": selected.compactMap { $0["misses"] as? Int }.reduce(0, +),
                               "failures": selected.compactMap { $0["failures"] as? Int }.reduce(0, +)])
            }
        }
        return ["sample_count": sampleCount, "preload_eligible_count": sampleCount - editedRAWExcluded,
                "edited_raw_exclusions": editedRAWExcluded, "raw_count_parsed_without_edits": rawIncluded,
                "dwell_ms": dwellMS, "base_ciimage_construction_median_ms": percentile(values("base_ciimage_construction"), 0.5) as Any? ?? NSNull(),
                "base_ciimage_construction_p95_ms": percentile(values("base_ciimage_construction"), 0.95) as Any? ?? NSNull(),
                "forced_native_raster_completion_median_ms": percentile(values("forced_native_raster_completion"), 0.5) as Any? ?? NSNull(),
                "forced_native_raster_completion_p95_ms": percentile(values("forced_native_raster_completion"), 0.95) as Any? ?? NSNull(),
                "preview_trials": trials]
    }
}
