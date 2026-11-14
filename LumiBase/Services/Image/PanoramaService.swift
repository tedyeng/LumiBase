import Foundation
import CoreImage
import ImageIO
import Vision
import simd
import AppKit

public struct PanoramaMergeOptions: Sendable {
    public var autoCrop: Bool
    public var useHomography: Bool
    public var maxFrameLongEdge: CGFloat
    public var outputFilename: String

    public init(
        autoCrop: Bool = true,
        useHomography: Bool = true,
        maxFrameLongEdge: CGFloat = 3600,
        outputFilename: String = "Panorama.dng"
    ) {
        self.autoCrop = autoCrop
        self.useHomography = useHomography
        self.maxFrameLongEdge = maxFrameLongEdge
        self.outputFilename = outputFilename
    }
}

public enum PanoramaError: LocalizedError {
    case insufficientImages
    case failedToLoadImage(String)
    case registrationFailed(String)
    case renderFailed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientImages:
            return "Select at least 2 overlapping photos to merge a panorama."
        case .failedToLoadImage(let name):
            return "Failed to decode source photo: \(name)"
        case .registrationFailed(let detail):
            return "Could not align photos into a panorama: \(detail)"
        case .renderFailed:
            return "Failed to render merged panorama image."
        case .writeFailed(let detail):
            return "Failed to write DNG file: \(detail)"
        }
    }
}

/// Pure-Swift 16-bit RGB Linear DNG writer producing standard `.dng` files readable by
/// `CIRAWFilter`, `ImageIO`, Preview, Finder QuickLook, Lightroom, and LumiBase.
public enum LinearDNGWriter {
    public struct Metadata {
        public var make: String?
        public var model: String?
        public var dateTime: String?
        public var software: String = "LumiBase Panorama"

        public init(make: String? = nil, model: String? = nil, dateTime: String? = nil) {
            self.make = make
            self.model = model
            self.dateTime = dateTime
        }
    }

    private struct IFDItem {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let payload: Data
    }

    private static func u16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }

    private static func u32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func i32(_ v: Int32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func ascii(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        return d
    }

    private static func srational(_ vals: [Double]) -> Data {
        var d = Data()
        for v in vals {
            d.append(i32(Int32((v * 10000.0).rounded())))
            d.append(i32(10000))
        }
        return d
    }

    private static func rational(_ vals: [Double]) -> Data {
        var d = Data()
        for v in vals {
            d.append(u32(UInt32(max(0.0, (v * 10000.0).rounded()))))
            d.append(u32(10000))
        }
        return d
    }

    /// Writes a 16-bit RGB Linear DNG file from a tightly packed `RGBA16` buffer (8 bytes/pixel, little-endian UInt16).
    public static func writeDNG(
        rgba16Buffer: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        iccProfileData: Data?,
        metadata: Metadata,
        to url: URL
    ) throws {
        guard width > 0, height > 0 else {
            throw PanoramaError.writeFailed("Invalid dimensions \(width)x\(height)")
        }

        let pixelCount = width * height
        var rgb16 = [UInt16](repeating: 0, count: pixelCount * 3)
        rgb16.withUnsafeMutableBufferPointer { dstBuf in
            guard let dstBase = dstBuf.baseAddress else { return }
            for i in 0..<pixelCount {
                let src = i * 4
                let dst = i * 3
                dstBase[dst] = rgba16Buffer[src]
                dstBase[dst + 1] = rgba16Buffer[src + 1]
                dstBase[dst + 2] = rgba16Buffer[src + 2]
            }
        }

        let stripByteCount = UInt32(pixelCount * 3 * 2)
        let makeStr = (metadata.make?.isEmpty == false) ? metadata.make! : "LumiBase"
        let modelStr = (metadata.model?.isEmpty == false) ? metadata.model! : "Panorama"
        let uniqueModel = "\(makeStr) \(modelStr)"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let dateStr = (metadata.dateTime?.isEmpty == false) ? metadata.dateTime! : formatter.string(from: Date())

        let items: [IFDItem] = [
            IFDItem(tag: 254, type: 4, count: 1, payload: u32(0)), // NewSubfileType
            IFDItem(tag: 256, type: 4, count: 1, payload: u32(UInt32(width))), // ImageWidth
            IFDItem(tag: 257, type: 4, count: 1, payload: u32(UInt32(height))), // ImageLength
            IFDItem(tag: 258, type: 3, count: 3, payload: u16(16) + u16(16) + u16(16)), // BitsPerSample
            IFDItem(tag: 259, type: 3, count: 1, payload: u16(1)), // Compression: None
            IFDItem(tag: 262, type: 3, count: 1, payload: u16(34892)), // PhotometricInterpretation: LinearRaw
            IFDItem(tag: 271, type: 2, count: UInt32(makeStr.utf8.count + 1), payload: ascii(makeStr)), // Make
            IFDItem(tag: 272, type: 2, count: UInt32(modelStr.utf8.count + 1), payload: ascii(modelStr)), // Model
            IFDItem(tag: 273, type: 4, count: 1, payload: u32(0)), // StripOffsets (patched below)
            IFDItem(tag: 274, type: 3, count: 1, payload: u16(1)), // Orientation: TopLeft
            IFDItem(tag: 277, type: 3, count: 1, payload: u16(3)), // SamplesPerPixel
            IFDItem(tag: 278, type: 4, count: 1, payload: u32(UInt32(height))), // RowsPerStrip
            IFDItem(tag: 279, type: 4, count: 1, payload: u32(stripByteCount)), // StripByteCounts
            IFDItem(tag: 284, type: 3, count: 1, payload: u16(1)), // PlanarConfiguration: Chunky
            IFDItem(tag: 305, type: 2, count: UInt32(metadata.software.utf8.count + 1), payload: ascii(metadata.software)), // Software
            IFDItem(tag: 306, type: 2, count: UInt32(dateStr.utf8.count + 1), payload: ascii(dateStr)), // DateTime
            IFDItem(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])), // DNGVersion
            IFDItem(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])), // DNGBackwardVersion
            IFDItem(tag: 50708, type: 2, count: UInt32(uniqueModel.utf8.count + 1), payload: ascii(uniqueModel)), // UniqueCameraModel
            IFDItem(tag: 50714, type: 5, count: 3, payload: rational([0, 0, 0])), // BlackLevel
            IFDItem(tag: 50717, type: 4, count: 3, payload: u32(65535) + u32(65535) + u32(65535)), // WhiteLevel
            IFDItem(tag: 50718, type: 5, count: 2, payload: rational([1.0, 1.0])), // DefaultScale
            IFDItem(tag: 50719, type: 5, count: 2, payload: rational([0.0, 0.0])), // DefaultCropOrigin
            IFDItem(tag: 50720, type: 5, count: 2, payload: rational([Double(width), Double(height)])), // DefaultCropSize
            IFDItem(tag: 50721, type: 10, count: 9, payload: srational([
                3.2404542, -1.5371385, -0.4985314,
                -0.9692660, 1.8760108, 0.0415560,
                0.0556434, -0.2040259, 1.0572252
            ])), // ColorMatrix1 (XYZ D65 -> Linear sRGB)
            IFDItem(tag: 50728, type: 5, count: 3, payload: rational([1.0, 1.0, 1.0])), // AsShotNeutral
            IFDItem(tag: 50778, type: 3, count: 1, payload: u16(21)), // CalibrationIlluminant1: D65
            IFDItem(tag: 50829, type: 4, count: 4, payload: u32(0) + u32(0) + u32(UInt32(height)) + u32(UInt32(width))) // ActiveArea
        ]

        let sorted = items.sorted { $0.tag < $1.tag }
        let ifdOffset: UInt32 = 8
        let headerSize = UInt32(2 + sorted.count * 12 + 4)

        var extra = Data()
        var entriesData = Data()
        var stripOffsetFieldPos: Int?

        for item in sorted {
            entriesData.append(u16(item.tag))
            entriesData.append(u16(item.type))
            entriesData.append(u32(item.count))
            if item.tag == 273 {
                stripOffsetFieldPos = entriesData.count
            }
            if item.payload.count <= 4 {
                var padded = item.payload
                while padded.count < 4 { padded.append(0) }
                entriesData.append(padded)
            } else {
                let off = ifdOffset + headerSize + UInt32(extra.count)
                entriesData.append(u32(off))
                extra.append(item.payload)
                if extra.count % 2 == 1 { extra.append(0) }
            }
        }

        var fileData = Data([0x49, 0x49]) // Little-endian TIFF
        fileData.append(u16(42))
        fileData.append(u32(ifdOffset))
        fileData.append(u16(UInt16(sorted.count)))
        fileData.append(entriesData)
        fileData.append(u32(0)) // Next IFD offset
        fileData.append(extra)

        let pixelOffset = UInt32(fileData.count)
        if let pos = stripOffsetFieldPos {
            fileData.replaceSubrange((Int(ifdOffset) + 2 + pos)..<(Int(ifdOffset) + 2 + pos + 4), with: u32(pixelOffset))
        }

        rgb16.withUnsafeBytes { fileData.append(contentsOf: $0) }
        try fileData.write(to: url, options: .atomic)
    }
}

/// Stitches multiple overlapping photos into a seamless 16-bit Linear DNG panorama using
/// horizon-leveled cylindrical projection, wide-baseline gradient correlation, radial lens vignette
/// compensation, and Voronoi-bounded dynamic-programming minimum-error seam blending.
public enum PanoramaService {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let cylWarpKernel = CIWarpKernel(source: """
        kernel vec2 panoCylWarp(float centerX, float centerY, float cx, float cy, float f, float cosR, float sinR) {
            vec2 d = destCoord();
            float theta = (d.x - centerX) / f;
            float px = f * tan(theta);
            float py = (d.y - centerY) / max(cos(theta), 0.1);
            float x = cx + cosR * px - sinR * py;
            float y = cy + sinR * px + cosR * py;
            return vec2(x, y);
        }
    """)

    private static let vignetteKernel = CIColorKernel(source: """
        kernel vec4 panoVignette(__sample s, float cx, float cy, float invMaxR2, float v1, float v2) {
            vec2 p = destCoord() - vec2(cx, cy);
            float r2 = dot(p, p) * invMaxR2;
            float gain = 1.0 + v1 * r2 + v2 * r2 * r2;
            return vec4(s.rgb * gain, s.a);
        }
    """)

    private static let weightedKernel = CIColorKernel(source: """
        kernel vec4 panoWeighted(__sample img, __sample mask) {
            float w = mask.r;
            return vec4(img.rgb * w, w);
        }
    """)

    private static let addKernel = CIColorKernel(source: """
        kernel vec4 panoAdd(__sample a, __sample b) {
            return a + b;
        }
    """)

    private static let normalizeKernel = CIColorKernel(source: """
        kernel vec4 panoNormalize(__sample accum) {
            float w = max(accum.a, 1e-5);
            vec3 rgb = clamp(accum.rgb / w, 0.0, 1.0);
            float alpha = accum.a > 1e-4 ? 1.0 : 0.0;
            return vec4(rgb, alpha);
        }
    """)

    private struct EdgeMap {
        let gx: [Float]
        let gy: [Float]
        let lum: [Float]
        let mag2: [Float]
    }

    /// Merges the given `assets` into a stitched 16-bit Linear DNG panorama written inside `outputDirectory`.
    public static func mergeToDNG(
        assets: [PhotoAsset],
        outputDirectory: URL,
        options: PanoramaMergeOptions,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard assets.count >= 2 else {
            throw PanoramaError.insufficientImages
        }
        guard let cylWarpKernel, let vignetteKernel, let weightedKernel, let addKernel, let normalizeKernel else {
            throw PanoramaError.renderFailed
        }

        var sortedAssets = assets.sorted { a, b in
            if let da = a.cameraMetadata.captureDate, let db = b.cameraMetadata.captureDate, da != db {
                return da < db
            }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }
        // Refresh XMP from disk sidecar if present so external or recent XMP edits (e.g. CropAngle, Exposure, SpotHeals) are always honored
        for i in 0..<sortedAssets.count {
            let diskXMP = XMPParser.loadXMP(for: sortedAssets[i].fileURL, fallbackEmbeddedXMP: sortedAssets[i].xmp)
            if diskXMP.hasDevelopEdits || diskXMP.hasCrop {
                sortedAssets[i].xmp = diskXMP
            }
        }

        let context = CIContext(options: [
            .workingColorSpace: linearSpace,
            .cacheIntermediates: false
        ])

        // 1. Decode unboosted linear frames (for LinearRaw DNG output) and registration proxies, locking WB to frame 0
        var rawFrames: [CIImage] = []
        var regSourceFrames: [CIImage] = []
        rawFrames.reserveCapacity(sortedAssets.count)
        regSourceFrames.reserveCapacity(sortedAssets.count)

        var lockedTemp: Float?
        var lockedTint: Float?
        let anchorExposure = sortedAssets.first?.xmp.exposure2012 ?? 0.0

        for (idx, asset) in sortedAssets.enumerated() {
            progress("Decoding photo \(idx + 1) of \(sortedAssets.count) (\(asset.filename))...")
            let relEV = Float((asset.xmp.exposure2012 ?? anchorExposure) - anchorExposure)
            guard let decoded = loadFramePair(
                asset: asset,
                maxLongEdge: options.maxFrameLongEdge,
                relativeExposureEV: relEV,
                lockedTemperature: &lockedTemp,
                lockedTint: &lockedTint
            ) else {
                throw PanoramaError.failedToLoadImage(asset.filename)
            }
            rawFrames.append(decoded.linearUnboosted)
            regSourceFrames.append(decoded.registrationToneMapped)
        }

        let fw = Float(rawFrames[0].extent.width)
        let fh = Float(rawFrames[0].extent.height)
        let sourceExtent = CGRect(x: 0, y: 0, width: CGFloat(fw), height: CGFloat(fh))

        // Determine 35mm equivalent focal length for cylindrical projection
        let rawFocal35 = sortedAssets.compactMap { $0.cameraMetadata.focalLength35mm ?? $0.cameraMetadata.focalLength }.first ?? 28.0
        let focal35mm = Float(min(max(rawFocal35, 14.0), 200.0))

        // 2. Build registration proxies (~560px width) and align in cylindrical space
        let regScale: Float = min(1.0, 560.0 / max(fw, 1.0))
        let rw = max(64, Int((fw * regScale).rounded()))
        let rh = max(64, Int((fh * regScale).rounded()))
        let regExtent = CGRect(x: 0, y: 0, width: rw, height: rh)

        let regImgs: [CIImage] = regSourceFrames.map { img in
            let s = CGFloat(regScale)
            let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            return scaled
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8])
                .cropped(to: regExtent)
        }

        let rfPx = Float(rw) * focal35mm / 36.0
        let rcx = Float(rw) * 0.5
        let maxTheta = atan(Float(rw) / (2.0 * rfPx))
        let halfValidW = max(16, Int(rfPx * maxTheta) - 6)
        let yMin = Int(Float(rh) * 0.20)
        let yMax = Int(Float(rh) * 0.80)

        func makeEdgeMap(_ img: CIImage, cy: Float, rollRad: Float, colorSpace: CGColorSpace) -> EdgeMap {
            let cosR = cos(rollRad)
            let sinR = sin(rollRad)
            let warped = cylWarpKernel.apply(
                extent: regExtent,
                roiCallback: { _, _ in regExtent },
                image: img,
                arguments: [rcx, cy, rcx, cy, rfPx, cosR, sinR]
            )?.cropped(to: regExtent) ?? img
            var rgba = [Float](repeating: 0, count: rw * rh * 4)
            context.render(warped, toBitmap: &rgba, rowBytes: rw * 16, bounds: regExtent, format: .RGBAf, colorSpace: colorSpace)
            var lum = [Float](repeating: 0, count: rw * rh)
            var gx = [Float](repeating: 0, count: rw * rh)
            var gy = [Float](repeating: 0, count: rw * rh)
            var m2 = [Float](repeating: 0, count: rw * rh)
            let horizonRow = Float(rh) - cy
            rgba.withUnsafeBufferPointer { rgbaPtr in
                lum.withUnsafeMutableBufferPointer { lumPtr in
                    for i in 0..<(rw * rh) {
                        lumPtr[i] = 0.2126 * rgbaPtr[i * 4] + 0.7152 * rgbaPtr[i * 4 + 1] + 0.0722 * rgbaPtr[i * 4 + 2]
                    }
                    gx.withUnsafeMutableBufferPointer { gxPtr in
                        gy.withUnsafeMutableBufferPointer { gyPtr in
                            m2.withUnsafeMutableBufferPointer { m2Ptr in
                                for y in 2..<(rh - 2) {
                                    let row = y * rw
                                    let distFromHorizon = abs(Float(y) - horizonRow) / Float(rh)
                                    let rowW = max(0.25, 1.0 - 2.2 * distFromHorizon)
                                    for x in 2..<(rw - 2) {
                                        let idx = row + x
                                        let dx = (lumPtr[idx + 1] - lumPtr[idx - 1]) * rowW
                                        let dy = (lumPtr[idx + rw] - lumPtr[idx - rw]) * rowW * 1.35
                                        gxPtr[idx] = dx
                                        gyPtr[idx] = dy
                                        m2Ptr[idx] = dx * dx + dy * dy
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return EdgeMap(gx: gx, gy: gy, lum: lum, mag2: m2)
        }

        func matchPair(
            _ ref: EdgeMap,
            _ flt: EdgeMap,
            searchDxRange: ClosedRange<Int>? = nil,
            searchDyRange: ClosedRange<Int>? = nil,
            step: Int = 2
        ) -> (dx: Int, dy: Int, ncc: Float) {
            let icx = rw / 2
            let dxRange = searchDxRange ?? (-Int(Float(rw) * 0.65)...Int(Float(rw) * 0.65))
            let dyRange = searchDyRange ?? (-Int(Float(rh) * 0.16)...Int(Float(rh) * 0.16))
            var bestNCC: Float = -1.0
            var bestDx = 0
            var bestDy = 0
            ref.gx.withUnsafeBufferPointer { rGx in
                ref.gy.withUnsafeBufferPointer { rGy in
                    ref.mag2.withUnsafeBufferPointer { rM2 in
                        flt.gx.withUnsafeBufferPointer { fGx in
                            flt.gy.withUnsafeBufferPointer { fGy in
                                flt.mag2.withUnsafeBufferPointer { fM2 in
                                    for dx in stride(from: dxRange.lowerBound, through: dxRange.upperBound, by: step) {
                                        if searchDxRange == nil && abs(dx) < Int(Float(rw) * 0.06) { continue }
                                        let midX = icx + dx / 2
                                        let corrHalf = max(28, min(abs(dx) / 2, 60))
                                        let ovMinX = max(icx - halfValidW, max(icx - halfValidW + dx, midX - corrHalf))
                                        let ovMaxX = min(icx + halfValidW, min(icx + halfValidW + dx, midX + corrHalf))
                                        if ovMaxX - ovMinX < 24 { continue }
                                        for dy in stride(from: dyRange.lowerBound, through: dyRange.upperBound, by: step) {
                                            var dot: Float = 0
                                            var eR: Float = 0
                                            var eF: Float = 0
                                            for y in stride(from: yMin, to: yMax, by: step) {
                                                let fy = y - dy
                                                if fy < yMin || fy >= yMax { continue }
                                                let rRow = y * rw
                                                let fRow = fy * rw
                                                for x in stride(from: ovMinX, to: ovMaxX, by: step) {
                                                    let rIdx = rRow + x
                                                    let fIdx = fRow + (x - dx)
                                                    dot += rGx[rIdx] * fGx[fIdx] + rGy[rIdx] * fGy[fIdx]
                                                    eR += rM2[rIdx]
                                                    eF += fM2[fIdx]
                                                }
                                            }
                                            let ncc = dot / max(1e-5, sqrt(eR * eF))
                                            if ncc > bestNCC {
                                                bestNCC = ncc
                                                bestDx = dx
                                                bestDy = dy
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return (bestDx, bestDy, bestNCC)
        }

        progress("Estimating horizon & aligning \(rawFrames.count) frames...")
        let userRoll0 = -Float(sortedAssets[0].xmp.cropAngle ?? 0.0) * .pi / 180.0
        let userRoll1 = -Float(sortedAssets[1].xmp.cropAngle ?? 0.0) * .pi / 180.0
        let em0Init = makeEdgeMap(regImgs[0], cy: Float(rh) * 0.45, rollRad: userRoll0, colorSpace: srgbSpace)
        let em1Init = makeEdgeMap(regImgs[1], cy: Float(rh) * 0.45, rollRad: userRoll1, colorSpace: srgbSpace)
        let coarse01 = matchPair(em0Init, em1Init)
        var bestCyFrac: Float = 0.45
        var bestCyNCC = coarse01.ncc
        for cyFrac in stride(from: Float(0.35), through: Float(0.62), by: Float(0.03)) {
            let cy = Float(rh) * cyFrac
            let e0 = makeEdgeMap(regImgs[0], cy: cy, rollRad: userRoll0, colorSpace: srgbSpace)
            let e1 = makeEdgeMap(regImgs[1], cy: cy, rollRad: userRoll1, colorSpace: srgbSpace)
            let m = matchPair(
                e0,
                e1,
                searchDxRange: (coarse01.dx - 6)...(coarse01.dx + 6),
                searchDyRange: (coarse01.dy - 4)...(coarse01.dy + 4),
                step: 2
            )
            if m.ncc > bestCyNCC {
                bestCyNCC = m.ncc
                bestCyFrac = cyFrac
            }
        }
        let rcy = Float(rh) * bestCyFrac

        var rolls = [Float](repeating: 0, count: rawFrames.count)
        rolls[0] = userRoll0
        var pairDx = [Int](repeating: 0, count: rawFrames.count - 1)
        var pairDy = [Int](repeating: 0, count: rawFrames.count - 1)
        var alignedMaps: [EdgeMap] = []
        alignedMaps.reserveCapacity(rawFrames.count)
        alignedMaps.append(makeEdgeMap(regImgs[0], cy: rcy, rollRad: userRoll0, colorSpace: srgbSpace))

        for i in 1..<rawFrames.count {
            progress("Aligning photo \(i + 1) of \(rawFrames.count)...")
            let prevMap = alignedMaps[i - 1]
            let userAngleDeg = Float(sortedAssets[i].xmp.cropAngle ?? 0.0)
            let userRoll = -userAngleDeg * .pi / 180.0
            let m0 = makeEdgeMap(regImgs[i], cy: rcy, rollRad: userRoll, colorSpace: srgbSpace)
            let c = matchPair(prevMap, m0)
            var bestRoll: Float = userRoll
            var bestMatch = matchPair(
                prevMap,
                m0,
                searchDxRange: (c.dx - 3)...(c.dx + 3),
                searchDyRange: (c.dy - 4)...(c.dy + 4),
                step: 1
            )
            var bestMap = m0

            // If user explicitly set CropAngle in XMP, never reduce or invert their horizon correction;
            // only allow up to +0.75° fine sub-degree refinement in the same direction to perfect seam alignment.
            let stepRange: ClosedRange<Int> = abs(userAngleDeg) > 0.01 ? (1...3) : (-6...6)
            let angleSign: Float = userAngleDeg >= 0 ? 1.0 : -1.0
            for degStep in stepRange {
                if degStep == 0 { continue }
                let candAngleDeg = abs(userAngleDeg) > 0.01
                    ? (userAngleDeg + angleSign * Float(degStep) * 0.25)
                    : (Float(degStep) * 0.25)
                let rad = -candAngleDeg * .pi / 180.0
                let candMap = makeEdgeMap(regImgs[i], cy: rcy, rollRad: rad, colorSpace: srgbSpace)
                let candMatch = matchPair(
                    prevMap,
                    candMap,
                    searchDxRange: (c.dx - 3)...(c.dx + 3),
                    searchDyRange: (c.dy - 4)...(c.dy + 4),
                    step: 1
                )
                if candMatch.ncc > bestMatch.ncc {
                    bestMatch = candMatch
                    bestRoll = rad
                    bestMap = candMap
                }
            }
            rolls[i] = bestRoll
            pairDx[i - 1] = bestMatch.dx
            pairDy[i - 1] = bestMatch.dy
            alignedMaps.append(bestMap)
        }

        // 3. Estimate radial lens vignette falloff in linear space from smooth overlapping pixels
        let linearMaps: [EdgeMap] = (0..<rawFrames.count).map { i in
            let s = CGFloat(regScale)
            let linSmall = rawFrames[i]
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8])
                .cropped(to: regExtent)
            return makeEdgeMap(linSmall, cy: rcy, rollRad: rolls[i], colorSpace: linearSpace)
        }

        let invMaxR2Reg = 1.0 / max(1.0, Float(rw * rw + rh * rh) * 0.25)
        var numV: Double = 0
        var denV: Double = 0
        let icx = rw / 2
        let icy = rh / 2
        for i in 1..<linearMaps.count {
            let ref = linearMaps[i - 1]
            let flt = linearMaps[i]
            let dx = pairDx[i - 1]
            let dy = pairDy[i - 1]
            let ovMinX = max(icx - halfValidW, icx - halfValidW + dx) + 8
            let ovMaxX = min(icx + halfValidW, icx + halfValidW + dx) - 8
            if ovMaxX <= ovMinX { continue }
            for y in stride(from: Int(Float(rh) * 0.08), to: Int(Float(rh) * 0.92), by: 2) {
                let fy = y - dy
                if fy < 4 || fy >= rh - 4 { continue }
                for x in stride(from: ovMinX, to: ovMaxX, by: 2) {
                    let fx = x - dx
                    let rIdx = y * rw + x
                    let fIdx = fy * rw + fx
                    if ref.mag2[rIdx] > 0.0004 || flt.mag2[fIdx] > 0.0004 { continue }
                    let ia = ref.lum[rIdx]
                    let ib = flt.lum[fIdx]
                    if ia < 0.015 || ia > 0.70 || ib < 0.015 || ib > 0.70 { continue }
                    let rA2 = Float((x - icx) * (x - icx) + (y - icy) * (y - icy)) * invMaxR2Reg
                    let rB2 = Float((fx - icx) * (fx - icx) + (fy - icy) * (fy - icy)) * invMaxR2Reg
                    let a = Double(ib * rB2 - ia * rA2)
                    let b = Double(ia - ib)
                    numV += a * b
                    denV += a * a
                }
            }
        }
        let estV1 = denV > 1e-4 ? Float(min(max(numV / denV, 0.0), 0.36)) : 0.22
        let estV2 = estV1 * 0.35

        let fullCx = fw * 0.5
        let fullCy = fh * bestCyFrac
        let invMaxR2Full = 1.0 / max(1.0, (fw * fw + fh * fh) * 0.25)
        let frames: [CIImage] = rawFrames.map { img in
            vignetteKernel.apply(
                extent: sourceExtent,
                arguments: [img, fullCx, fh * 0.5, invMaxR2Full, estV1, estV2]
            )?.cropped(to: sourceExtent) ?? img
        }

        // 4. Compute global positions in full-scale cylindrical canvas coordinates
        let fullScale = 1.0 / regScale
        var posX = [Float](repeating: 0, count: frames.count)
        var posY = [Float](repeating: 0, count: frames.count)
        for i in 1..<frames.count {
            posX[i] = posX[i - 1] + Float(pairDx[i - 1]) * fullScale
            // Note: ctx.render has y=0 at top, whereas CoreImage has y=0 at bottom
            posY[i] = posY[i - 1] - Float(pairDy[i - 1]) * fullScale
        }

        let order = (0..<frames.count).sorted { posX[$0] < posX[$1] }
        let minPosX = order.map { posX[$0] }.min() ?? 0
        let meanPosY = posY.reduce(0, +) / Float(max(posY.count, 1))
        for i in 0..<frames.count {
            posX[i] -= minPosX
            posY[i] -= meanPosY
        }

        let fullF = fw * focal35mm / 36.0
        let fullHalfValidW = fullF * atan(fw / (2.0 * fullF)) - 10.0

        let canvasMinX = Int((posX[order.first!] + fullCx - fullHalfValidW).rounded(.up))
        let canvasMaxX = Int((posX[order.last!] + fullCx + fullHalfValidW).rounded(.down))
        let cosThetaMax = cos(atan(fw / (2.0 * fullF)))
        let maxAbsPosY = posY.map { abs($0) }.max() ?? 0
        let maxRollSin = rolls.map { abs(sin($0)) }.max() ?? 0
        let rollMargin = fw * 0.5 * maxRollSin + 8.0

        let canvasMinY: Int
        let canvasMaxY: Int
        if options.autoCrop {
            let validTopY = fullCy + (fh - fullCy) * cosThetaMax - maxAbsPosY - rollMargin
            let validBotY = fullCy - fullCy * cosThetaMax + maxAbsPosY + rollMargin
            canvasMinY = Int(validBotY.rounded(.up))
            canvasMaxY = Int(validTopY.rounded(.down))
        } else {
            let minPosY = posY.min() ?? 0
            let maxPosY = posY.max() ?? 0
            canvasMinY = Int(minPosY.rounded(.down))
            canvasMaxY = Int((fh + maxPosY).rounded(.up))
        }

        var canvasRect = CGRect(
            x: canvasMinX,
            y: canvasMinY,
            width: max(128, canvasMaxX - canvasMinX),
            height: max(128, canvasMaxY - canvasMinY)
        )

        var warpedFrames: [CIImage] = []
        warpedFrames.reserveCapacity(order.count)
        for idx in order {
            let cxCanvas = posX[idx] + fullCx
            let cyCanvas = posY[idx] + fullCy
            let cosR = cos(rolls[idx])
            let sinR = sin(rolls[idx])
            let clampedSrc = frames[idx].clampedToExtent()
            guard let wImg = cylWarpKernel.apply(
                extent: canvasRect,
                roiCallback: { _, _ in sourceExtent },
                image: clampedSrc,
                arguments: [cxCanvas, cyCanvas, fullCx, fullCy, fullF, cosR, sinR]
            )?.cropped(to: canvasRect) else {
                throw PanoramaError.renderFailed
            }
            warpedFrames.append(wImg)
        }

        // 5. Compute Voronoi-bounded dynamic-programming minimum-error seams at 1/4 canvas scale
        progress("Finding optimal seams across \(frames.count) frames...")
        let seamScale: CGFloat = min(0.25, 1200.0 / max(canvasRect.width, 1.0))
        let sw = max(32, Int((canvasRect.width * seamScale).rounded()))
        let sh = max(32, Int((canvasRect.height * seamScale).rounded()))
        let seamRect = CGRect(x: 0, y: 0, width: sw, height: sh)

        var smallBuffers: [[Float]] = []
        smallBuffers.reserveCapacity(warpedFrames.count)
        for wImg in warpedFrames {
            let shifted = wImg
                .transformed(by: CGAffineTransform(translationX: -canvasRect.minX, y: -canvasRect.minY))
                .transformed(by: CGAffineTransform(scaleX: seamScale, y: seamScale))
            var buf = [Float](repeating: 0, count: sw * sh * 4)
            context.render(shifted, toBitmap: &buf, rowBytes: sw * 16, bounds: seamRect, format: .RGBAf, colorSpace: linearSpace)
            smallBuffers.append(buf)
        }

        var gains = [Float](repeating: 1.0, count: order.count)
        var seamPaths: [[Float]] = []
        var seamHalfWidths: [[Float]] = []

        for k in 1..<order.count {
            let prevIdx = order[k - 1]
            let currIdx = order[k]
            let cPrev = posX[prevIdx] + fullCx
            let cCurr = posX[currIdx] + fullCx
            let midCanvasX = 0.5 * (cPrev + cCurr)
            let stepSpan = max(32.0, cCurr - cPrev)
            let corridorHalfW = min(stepSpan * 0.36, fullHalfValidW * 0.45)
            let rawOvMin = max(cPrev - fullHalfValidW, cCurr - fullHalfValidW)
            let rawOvMax = min(cPrev + fullHalfValidW, cCurr + fullHalfValidW)
            let ovMinCanvasX = max(rawOvMin + 12.0, midCanvasX - corridorHalfW)
            let ovMaxCanvasX = min(rawOvMax - 12.0, midCanvasX + corridorHalfW)

            let sMinX = max(2, Int(((ovMinCanvasX - Float(canvasRect.minX)) * Float(seamScale)).rounded()) + 2)
            let sMaxX = min(sw - 3, max(sMinX + 6, Int(((ovMaxCanvasX - Float(canvasRect.minX)) * Float(seamScale)).rounded()) - 2))
            let ovW = max(6, sMaxX - sMinX)

            let bufA = smallBuffers[k - 1]
            let bufB = smallBuffers[k]
            var sumA: Double = 0
            var sumB: Double = 0
            for y in stride(from: Int(Double(sh) * 0.15), to: Int(Double(sh) * 0.85), by: 2) {
                for x in stride(from: sMinX, through: sMaxX, by: 2) {
                    let p = (y * sw + x) * 4
                    let la = Double(0.2126 * bufA[p] + 0.7152 * bufA[p + 1] + 0.0722 * bufA[p + 2])
                    let lb = Double(0.2126 * bufB[p] + 0.7152 * bufB[p + 1] + 0.0722 * bufB[p + 2])
                    if la > 0.01 && la < 0.65 && lb > 0.01 && lb < 0.65 {
                        sumA += la
                        sumB += lb
                    }
                }
            }
            let prevGain = gains[k - 1]
            let relGain = sumB > 0.5 ? Float(sumA / sumB) : 1.0
            let clampedRel = min(max(relGain, 0.94), 1.06)
            let currGain = min(max(prevGain * clampedRel, 0.90), 1.10)
            gains[k] = currGain

            var dp = [Float](repeating: 0, count: ovW * sh)
            var back = [Int8](repeating: 0, count: ovW * sh)
            let midX = Float(sMinX + sMaxX) * 0.5
            let invHalfW = 2.0 / Float(max(ovW, 1))

            bufA.withUnsafeBufferPointer { pA in
                bufB.withUnsafeBufferPointer { pB in
                    dp.withUnsafeMutableBufferPointer { dpPtr in
                        back.withUnsafeMutableBufferPointer { backPtr in
                            for y in 0..<sh {
                                let yDown = min(sh - 1, y + 1)
                                for xi in 0..<ovW {
                                    let x = sMinX + xi
                                    let p = (y * sw + x) * 4
                                    let dr = abs(pA[p] * prevGain - pB[p] * currGain)
                                    let dg = abs(pA[p + 1] * prevGain - pB[p + 1] * currGain)
                                    let db = abs(pA[p + 2] * prevGain - pB[p + 2] * currGain)
                                    let colorCost = dr + dg + db

                                    let pNext = (y * sw + min(sw - 1, x + 1)) * 4
                                    let pDown = (yDown * sw + x) * 4
                                    let gradAx = abs(pA[pNext] - pA[p]) + abs(pA[pNext + 1] - pA[p + 1])
                                    let gradBx = abs(pB[pNext] - pB[p]) + abs(pB[pNext + 1] - pB[p + 1])
                                    let gradAy = abs(pA[pDown] - pA[p]) + abs(pA[pDown + 1] - pA[p + 1])
                                    let gradBy = abs(pB[pDown] - pB[p]) + abs(pB[pDown + 1] - pB[p + 1])
                                    let gradCost = (abs(gradAx - gradBx) + abs(gradAy - gradBy)) * 3.0
                                    let dMid = (Float(x) - midX) * invHalfW
                                    let centerBias = 0.04 * dMid * dMid
                                    let cost = colorCost + gradCost + centerBias

                                    if y == 0 {
                                        dpPtr[xi] = cost
                                    } else {
                                        let prevRow = (y - 1) * ovW
                                        var bestPrev = dpPtr[prevRow + xi]
                                        var bestDir: Int8 = 0
                                        if xi > 0 && dpPtr[prevRow + xi - 1] < bestPrev {
                                            bestPrev = dpPtr[prevRow + xi - 1]
                                            bestDir = -1
                                        }
                                        if xi + 1 < ovW && dpPtr[prevRow + xi + 1] < bestPrev {
                                            bestPrev = dpPtr[prevRow + xi + 1]
                                            bestDir = 1
                                        }
                                        dpPtr[y * ovW + xi] = cost + bestPrev
                                        backPtr[y * ovW + xi] = bestDir
                                    }
                                }
                            }
                        }
                    }
                }
            }

            var bestEndXi = 0
            var bestEndCost = Float.greatestFiniteMagnitude
            let lastRow = (sh - 1) * ovW
            for xi in 0..<ovW {
                if dp[lastRow + xi] < bestEndCost {
                    bestEndCost = dp[lastRow + xi]
                    bestEndXi = xi
                }
            }

            var rawSeam = [Float](repeating: 0, count: sh)
            var rawGrad = [Float](repeating: 0, count: sh)
            var curXi = bestEndXi
            for y in stride(from: sh - 1, through: 0, by: -1) {
                let sx = sMinX + curXi
                rawSeam[y] = Float(sx) / Float(seamScale) + Float(canvasRect.minX)
                var gSum: Float = 0
                for dx in -4...4 {
                    let xx = min(max(sx + dx, 1), sw - 2)
                    let p0 = (y * sw + xx) * 4
                    let p1 = (y * sw + xx + 1) * 4
                    let py1 = (min(sh - 1, y + 1) * sw + xx) * 4
                    gSum += abs(bufA[p1] - bufA[p0]) + abs(bufA[py1] - bufA[p0]) + abs(bufB[p1] - bufB[p0]) + abs(bufB[py1] - bufB[p0])
                }
                rawGrad[y] = gSum / 9.0
                curXi = max(0, min(ovW - 1, curXi + Int(back[y * ovW + curXi])))
            }

            var smoothSeam = [Float](repeating: 0, count: sh)
            var rowHalfW = [Float](repeating: 0, count: sh)
            let maxAllowedW = max(16.0, Float(ovMaxCanvasX - ovMinCanvasX) * 0.42)
            for y in 0..<sh {
                var s: Float = 0
                var g: Float = 0
                var c: Float = 0
                for dy in -10...10 {
                    let ny = min(max(y + dy, 0), sh - 1)
                    s += rawSeam[ny]
                    g += rawGrad[ny]
                    c += 1
                }
                let sc = s / c
                let gc = g / c
                let t = min(max((gc - 0.008) / 0.035, 0.0), 1.0)
                let adaptiveW = (1.0 - t) * min(140.0, maxAllowedW) + t * 12.0
                let distToEdges = max(8.0, min(sc - (ovMinCanvasX + 4.0), (ovMaxCanvasX - 4.0) - sc))
                smoothSeam[y] = sc
                rowHalfW[y] = min(adaptiveW, distToEdges)
            }
            seamPaths.append(smoothSeam)
            seamHalfWidths.append(rowHalfW)
        }

        // 6. Blend frames using gradient-adaptive seam masks and partition-of-unity normalization
        progress("Blending \(frames.count) frames...")
        var accumImg: CIImage?
        for k in 0..<order.count {
            let g = gains[k]
            var frameImg = warpedFrames[k]
            if abs(g - 1.0) > 1e-4 {
                frameImg = frameImg.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(g), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(g), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(g), w: 0)
                ])
            }

            var maskBytes = [UInt8](repeating: 0, count: sw * sh * 4)
            for y in 0..<sh {
                let leftSeamX: Float? = k > 0 ? seamPaths[k - 1][y] : nil
                let rightSeamX: Float? = (k + 1 < order.count) ? seamPaths[k][y] : nil
                let leftW: Float = k > 0 ? seamHalfWidths[k - 1][y] : 1.0
                let rightW: Float = (k + 1 < order.count) ? seamHalfWidths[k][y] : 1.0

                for x in 0..<sw {
                    let canvasX = (Float(x) + 0.5) / Float(seamScale) + Float(canvasRect.minX)
                    let leftCDF: Float = leftSeamX != nil ? smoothstep(leftSeamX! - leftW, leftSeamX! + leftW, canvasX) : 1.0
                    let rightCDF: Float = rightSeamX != nil ? smoothstep(rightSeamX! - rightW, rightSeamX! + rightW, canvasX) : 0.0
                    let w = max(0.0, leftCDF - rightCDF)
                    let p = (y * sw + x) * 4
                    let b = UInt8(min(max((w * 255.0).rounded(), 0), 255))
                    maskBytes[p] = b
                    maskBytes[p + 1] = b
                    maskBytes[p + 2] = b
                    maskBytes[p + 3] = 255
                }
            }

            let maskData = Data(maskBytes)
            let smallMask = CIImage(
                bitmapData: maskData,
                bytesPerRow: sw * 4,
                size: CGSize(width: sw, height: sh),
                format: .RGBA8,
                colorSpace: nil
            )
            let fullMask = smallMask
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 1.0 / seamScale, y: 1.0 / seamScale))
                .transformed(by: CGAffineTransform(translationX: canvasRect.minX, y: canvasRect.minY))
                .cropped(to: canvasRect)

            guard let weighted = weightedKernel.apply(extent: canvasRect, arguments: [frameImg, fullMask]) else {
                continue
            }
            if let prev = accumImg {
                accumImg = addKernel.apply(extent: canvasRect, arguments: [prev, weighted])
            } else {
                accumImg = weighted
            }
        }

        guard let accum = accumImg,
              let finalLinear = normalizeKernel.apply(extent: canvasRect, arguments: [accum]) else {
            throw PanoramaError.renderFailed
        }

        // Cap extreme canvas dimensions if needed
        let maxCanvasDim: CGFloat = 16384
        var outputImage = finalLinear
        let canvasScale = min(1.0, maxCanvasDim / max(canvasRect.width, canvasRect.height))
        if canvasScale < 1.0 {
            outputImage = finalLinear.transformed(by: CGAffineTransform(scaleX: canvasScale, y: canvasScale))
            canvasRect = outputImage.extent.integral
        }

        // 7. Render to 16-bit Linear RGB and write LinearRaw DNG
        progress("Writing 16-bit DNG panorama...")
        let outW = Int(canvasRect.width)
        let outH = Int(canvasRect.height)
        guard outW > 0, outH > 0 else {
            throw PanoramaError.renderFailed
        }

        var rgba16 = [UInt16](repeating: 0, count: outW * outH * 4)
        rgba16.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            context.render(
                outputImage,
                toBitmap: base,
                rowBytes: outW * 8,
                bounds: canvasRect,
                format: .RGBA16,
                colorSpace: linearSpace
            )
        }

        let outputURL = uniqueOutputURL(in: outputDirectory, preferredFilename: options.outputFilename)
        let firstMeta = sortedAssets.first?.cameraMetadata
        let dngMeta = LinearDNGWriter.Metadata(
            make: firstMeta?.make,
            model: firstMeta?.model,
            dateTime: nil
        )
        let iccData = srgbSpace.copyICCData() as Data?

        try rgba16.withUnsafeBufferPointer { bufPtr in
            guard let base = bufPtr.baseAddress else { throw PanoramaError.renderFailed }
            try LinearDNGWriter.writeDNG(
                rgba16Buffer: base,
                width: outW,
                height: outH,
                iccProfileData: iccData,
                metadata: dngMeta,
                to: outputURL
            )
        }

        // Copy non-crop develop settings from the first source photo to the new panorama's XMP sidecar
        if let firstAsset = sortedAssets.first {
            var panoXMP = firstAsset.xmp
            panoXMP.resetCrop()
            panoXMP.spotHeals = []
            if panoXMP.hasDevelopEdits || panoXMP.rating > 0 || panoXMP.flag != .unflagged || panoXMP.colorLabel != .none {
                let xmpURL = outputURL.deletingPathExtension().appendingPathExtension("xmp")
                try? XMPWriter.write(metadata: panoXMP, to: xmpURL, originalFilename: outputURL.lastPathComponent)
            }
        }

        return outputURL
    }

    // MARK: - Helpers

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(1e-5, edge1 - edge0), 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private static func loadFramePair(
        asset: PhotoAsset,
        maxLongEdge: CGFloat,
        relativeExposureEV: Float,
        lockedTemperature: inout Float?,
        lockedTint: inout Float?
    ) -> (linearUnboosted: CIImage, registrationToneMapped: CIImage)? {
        if asset.isRaw,
           let rfLinear = CIRAWFilter(imageURL: asset.fileURL),
           let rfReg = CIRAWFilter(imageURL: asset.fileURL) {
            if let temp = lockedTemperature, let tint = lockedTint {
                rfLinear.neutralTemperature = temp
                rfLinear.neutralTint = tint
                rfReg.neutralTemperature = temp
                rfReg.neutralTint = tint
            } else {
                let temp = asset.xmp.temperature.map { Float($0) } ?? rfLinear.neutralTemperature
                let tint = asset.xmp.tint.map { Float($0) } ?? rfLinear.neutralTint
                lockedTemperature = temp
                lockedTint = tint
                rfLinear.neutralTemperature = temp
                rfLinear.neutralTint = tint
                rfReg.neutralTemperature = temp
                rfReg.neutralTint = tint
            }

            let native = rfLinear.nativeSize
            let longEdge = max(native.width, native.height)
            let scale: Float = (longEdge > maxLongEdge && longEdge > 0) ? Float(maxLongEdge / longEdge) : 1.0

            rfLinear.scaleFactor = scale
            rfLinear.exposure = relativeExposureEV
            rfLinear.shadowBias = 0.0
            rfLinear.boostShadowAmount = 0.0
            rfLinear.boostAmount = 0.0
            rfLinear.isLensCorrectionEnabled = true

            rfReg.scaleFactor = scale
            rfReg.exposure = relativeExposureEV
            rfReg.shadowBias = 0.0
            rfReg.boostShadowAmount = 0.0
            rfReg.boostAmount = 1.0
            rfReg.isLensCorrectionEnabled = true

            guard let linOut = rfLinear.outputImage, let regOut = rfReg.outputImage else {
                return nil
            }
            var linNorm = normalizeOrigin(linOut)
            var regNorm = normalizeOrigin(regOut)
            if !asset.xmp.spotHeals.isEmpty {
                linNorm = SpotHealKernel.apply(image: linNorm, spots: asset.xmp.spotHeals)
                regNorm = SpotHealKernel.apply(image: regNorm, spots: asset.xmp.spotHeals)
            }
            return (linNorm, regNorm)
        }

        if let loaded = CIImage(contentsOf: asset.fileURL, options: [.applyOrientationProperty: true]) {
            let longEdge = max(loaded.extent.width, loaded.extent.height)
            let scaled: CIImage
            if longEdge > maxLongEdge, longEdge > 0 {
                let s = maxLongEdge / longEdge
                scaled = loaded.transformed(by: CGAffineTransform(scaleX: s, y: s))
            } else {
                scaled = loaded
            }
            var norm = normalizeOrigin(scaled)
            if abs(relativeExposureEV) > 1e-3 {
                norm = norm.applyingFilter("CIExposureAdjust", parameters: ["inputEV": relativeExposureEV])
            }
            if !asset.xmp.spotHeals.isEmpty {
                norm = SpotHealKernel.apply(image: norm, spots: asset.xmp.spotHeals)
            }
            return (norm, norm)
        }

        return nil
    }

    private static func normalizeOrigin(_ img: CIImage) -> CIImage {
        let origin = img.extent.origin
        if origin != .zero {
            return img.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }
        return img
    }

    private static func uniqueOutputURL(in directory: URL, preferredFilename: String) -> URL {
        var cleanName = preferredFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty { cleanName = "Panorama.dng" }
        if !cleanName.lowercased().hasSuffix(".dng") {
            cleanName += ".dng"
        }
        let base = (cleanName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent("\(base).dng")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).dng")
            counter += 1
        }
        return candidate
    }
}
