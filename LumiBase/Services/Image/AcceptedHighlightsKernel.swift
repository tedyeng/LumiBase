import AppKit
import CoreImage
import Foundation

/// Immutable, globally phased log-luminance correction prepared from the two legacy endpoints.
struct AcceptedHighlightsField {
    let correctionImage: CIImage
    let extent: CGRect
    let quarterWidth: Int
    let quarterHeight: Int
    let data: Data?

    init(correctionImage: CIImage, extent: CGRect, quarterWidth: Int, quarterHeight: Int, data: Data? = nil) {
        self.correctionImage = correctionImage
        self.extent = extent
        self.quarterWidth = quarterWidth
        self.quarterHeight = quarterHeight
        self.data = data
    }
}

/// Native accepted-B transform. `prepare` is intentionally synchronous: callers must run it
/// off the main thread. The only CPU work is on the quarter-resolution global guide field.
enum AcceptedHighlightsKernel {
    enum KernelError: Error {
        case mismatchedExtents
        case invalidExtent
        case renderFailed
        case kernelUnavailable
    }

    private static let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!

    /// Produces the accepted globally anchored `[::4, ::4]` field and its two 97-wide
    /// reflect-padded box-filter passes. Input CIImages are the already processed legacy endpoints.
    static func prepare(baseline: CIImage, target: CIImage, context: CIContext) throws -> AcceptedHighlightsField {
        try Task.checkCancellation()
        guard colorKernel != nil else { throw KernelError.kernelUnavailable }
        guard baseline.extent == target.extent else { throw KernelError.mismatchedExtents }
        let extent = baseline.extent.integral
        guard !extent.isInfinite, !extent.isEmpty,
              extent.width * extent.height <= 128_000_000 else { throw KernelError.invalidExtent }
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, extent.width == baseline.extent.width,
              extent.height == baseline.extent.height else { throw KernelError.invalidExtent }
        let lowWidth = (width + 3) / 4, lowHeight = (height + 3) / 4
        // Read full-width bands and select exact top-left `[::4, ::4]` samples. CI's
        // bottom-left origin means the first selected storage row is (height-1) mod 4.
        let lowBaseline = try renderQuarterRGBA(baseline, extent: extent, context: context,
                                                fullWidth: width, fullHeight: height,
                                                lowWidth: lowWidth, lowHeight: lowHeight)
        let lowTarget = try renderQuarterRGBA(target, extent: extent, context: context,
                                              fullWidth: width, fullHeight: height,
                                              lowWidth: lowWidth, lowHeight: lowHeight)

        let count = lowWidth * lowHeight
        var guide = [Float](repeating: 0, count: count)
        var detail = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let bi = i * 4, ti = i * 4
            let br = quantizeSRGBLinear(lowBaseline[bi])
            let bg = quantizeSRGBLinear(lowBaseline[bi + 1])
            let bb = quantizeSRGBLinear(lowBaseline[bi + 2])
            let tr = quantizeSRGBLinear(lowTarget[ti])
            let tg = quantizeSRGBLinear(lowTarget[ti + 1])
            let tb = quantizeSRGBLinear(lowTarget[ti + 2])
            let ber = encodeSRGB(br), beg = encodeSRGB(bg), beb = encodeSRGB(bb)
            let gate = smooth((0.2126 * ber + 0.7152 * beg + 0.0722 * beb) * 255, 80, 200)
            let cr = br * (1 - gate) + tr * gate
            let cg = bg * (1 - gate) + tg * gate
            let cb = bb * (1 - gate) + tb * gate
            let targetY = max(0.2126 * tr + 0.7152 * tg + 0.0722 * tb, 1e-6)
            let fusedY = max(0.2126 * cr + 0.7152 * cg + 0.0722 * cb, 1e-6)
            guide[i] = Float(log2(targetY))
            detail[i] = Float(log2(fusedY) - log2(targetY))
        }

        let meanGuide = boxMean(guide, width: lowWidth, height: lowHeight)
        let meanDetail = boxMean(detail, width: lowWidth, height: lowHeight)
        var guideDetail = [Float](repeating: 0, count: count)
        var guideSquared = [Float](repeating: 0, count: count)
        for i in 0..<count {
            guideDetail[i] = guide[i] * detail[i]
            guideSquared[i] = guide[i] * guide[i]
        }
        let meanGuideDetail = boxMean(guideDetail, width: lowWidth, height: lowHeight)
        let meanGuideSquared = boxMean(guideSquared, width: lowWidth, height: lowHeight)
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let variance = max(meanGuideSquared[i] - meanGuide[i] * meanGuide[i], 0)
            a[i] = (meanGuideDetail[i] - meanGuide[i] * meanDetail[i]) / (variance + 0.25 * 0.25)
            b[i] = meanDetail[i] - a[i] * meanGuide[i]
        }
        let meanA = boxMean(a, width: lowWidth, height: lowHeight)
        let meanB = boxMean(b, width: lowWidth, height: lowHeight)
        var correction = [Float](repeating: 0, count: count)
        for i in 0..<count { correction[i] = meanA[i] * guide[i] + meanB[i] }

        let bytes = correction.withUnsafeBufferPointer { Data(buffer: $0) }
        let lowImage = CIImage(bitmapData: bytes, bytesPerRow: lowWidth * MemoryLayout<Float>.size,
                               size: CGSize(width: lowWidth, height: lowHeight), format: .Rf,
                               colorSpace: nil)
        let sx = extent.width / CGFloat(lowWidth), sy = extent.height / CGFloat(lowHeight)
        let resize = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                       tx: extent.minX, ty: extent.minY)
        let fullCorrection = lowImage.transformed(by: resize).cropped(to: extent)
        return AcceptedHighlightsField(correctionImage: fullCorrection, extent: extent,
                                       quarterWidth: lowWidth, quarterHeight: lowHeight, data: bytes)
    }

    /// Applies the exact accepted pixel stages as a Core Image color kernel (Metal-backed on GPU).
    /// The returned CIImage retains the full source extent, so cropped rendering uses global field coordinates.
    static func apply(baseline: CIImage, target: CIImage, field: AcceptedHighlightsField) -> CIImage {
        precondition(baseline.extent == target.extent && baseline.extent == field.extent,
                     "Accepted highlights inputs and field must share the same full-image extent")
        guard let kernel = colorKernel else { fatalError("Core Image failed to compile the accepted highlights GPU kernel") }
        return kernel.apply(extent: field.extent, arguments: [baseline, target, field.correctionImage])!
    }

    private static func renderQuarterRGBA(_ image: CIImage, extent: CGRect, context: CIContext,
                                          fullWidth: Int, fullHeight: Int,
                                          lowWidth: Int, lowHeight: Int) throws -> [Float] {
        let bandHeight = 96
        let phase = (fullHeight - 1) % 4
        var low = [Float](repeating: 0, count: lowWidth * lowHeight * 4)
        for y0 in stride(from: 0, to: fullHeight, by: bandHeight) {
            try Task.checkCancellation()
            let rows = min(bandHeight, fullHeight - y0)
            var band = [Float](repeating: 0, count: fullWidth * rows * 4)
            band.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: fullWidth * 16,
                               bounds: CGRect(x: extent.minX, y: extent.minY + CGFloat(y0),
                                              width: CGFloat(fullWidth), height: CGFloat(rows)),
                               format: .RGBAf, colorSpace: linearSRGB)
            }
            for localY in 0..<rows {
                // CI bitmap buffers are ordered top-to-bottom within each requested band.
                let globalY = y0 + rows - 1 - localY
                guard globalY >= phase, (globalY - phase) % 4 == 0 else { continue }
                let lowY = (fullHeight - 1 - globalY) / 4
                for lowX in 0..<lowWidth {
                    let source = (localY * fullWidth + lowX * 4) * 4
                    let destination = (lowY * lowWidth + lowX) * 4
                    low[destination] = band[source]
                    low[destination + 1] = band[source + 1]
                    low[destination + 2] = band[source + 2]
                    low[destination + 3] = band[source + 3]
                }
            }
        }
        guard low.allSatisfy({ $0.isFinite }) else { throw KernelError.renderFailed }
        return low
    }

    private static func quantizeSRGBLinear(_ linear: Float) -> Double {
        let encoded = min(max(encodeSRGB(Double(linear)), 0), 1)
        let q = (encoded * 65535).rounded() / 65535
        return decodeSRGB(q)
    }

    private static func encodeSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(max(value, 0), 1 / 2.4) - 0.055
    }

    private static func decodeSRGB(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    @inline(__always) private static func smooth(_ value: Double, _ low: Double, _ high: Double) -> Double {
        let x = min(max((value - low) / (high - low), 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// scipy.ndimage.uniform_filter(size: 97, mode: "reflect") semantics, using separable
    /// sliding windows and half-sample symmetric border reflection.
    private static func boxMean(_ input: [Float], width: Int, height: Int) -> [Float] {
        let radius = 48, divisor: Float = 97
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for offset in -radius...radius { sum += input[row + reflect(offset, count: width)] }
            for x in 0..<width {
                horizontal[row + x] = sum / divisor
                sum += input[row + reflect(x + radius + 1, count: width)]
                sum -= input[row + reflect(x - radius, count: width)]
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var sum: Float = 0
            for offset in -radius...radius { sum += horizontal[reflect(offset, count: height) * width + x] }
            for y in 0..<height {
                output[y * width + x] = sum / divisor
                sum += horizontal[reflect(y + radius + 1, count: height) * width + x]
                sum -= horizontal[reflect(y - radius, count: height) * width + x]
            }
        }
        return output
    }

    @inline(__always) private static func reflect(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = count * 2
        let folded = ((index % period) + period) % period
        return folded < count ? folded : period - folded - 1
    }

    private static let colorKernel = CIColorKernel(source: #"""
        float sat(float x, float a, float b) { float v = clamp((x-a)/(b-a), 0.0, 1.0); return v*v*(3.0-2.0*v); }
        float3 enc(float3 x) {
            float3 low = x * 12.92;
            float3 hi = 1.055 * pow(max(x, float3(0.0)), float3(1.0/2.4)) - 0.055;
            return clamp(float3(x.r <= 0.0031308 ? low.r : hi.r,
                                x.g <= 0.0031308 ? low.g : hi.g,
                                x.b <= 0.0031308 ? low.b : hi.b), 0.0, 1.0);
        }
        float3 dec(float3 x) {
            float3 low = x / 12.92;
            float3 hi = pow((x + 0.055) / 1.055, float3(2.4));
            return float3(x.r <= 0.04045 ? low.r : hi.r,
                          x.g <= 0.04045 ? low.g : hi.g,
                          x.b <= 0.04045 ? low.b : hi.b);
        }
        float3 q16(float3 x) { return dec(floor(enc(x) * 65535.0 + 0.5) / 65535.0); }
        float3 lab(float3 c) {
            float l = pow(max(0.4122214708*c.r + 0.5363325363*c.g + 0.0514459929*c.b, 0.0), 1.0/3.0);
            float m = pow(max(0.2119034982*c.r + 0.6806995451*c.g + 0.1073969566*c.b, 0.0), 1.0/3.0);
            float s = pow(max(0.0883024619*c.r + 0.2817188376*c.g + 0.6299787005*c.b, 0.0), 1.0/3.0);
            return float3(0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
                          1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
                          0.0259040371*l + 0.7827717662*m - 0.8086757660*s);
        }
        float3 invlab(float3 c) {
            float l = c.x + 0.3963377774*c.y + 0.2158037573*c.z;
            float m = c.x - 0.1055613458*c.y - 0.0638541728*c.z;
            float s = c.x - 0.0894841775*c.y - 1.2914855480*c.z;
            l=l*l*l; m=m*m*m; s=s*s*s;
            return float3(4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
                         -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
                         -0.0041960863*l - 0.7034186147*m + 1.7076147010*s);
        }
        kernel vec4 accepted(__sample baseline, __sample target, __sample correction) {
            float3 be = q16(baseline.rgb);
            float3 te = q16(target.rgb);
            float3 bs = enc(be);
            float d = correction.r;
            float3 z = te * exp2(d);
            float3 l = lab(z);
            float warm = sat(l.x,0.35,0.75)*sat(l.z,0.015,0.07)*sat(l.y,-0.01,0.04)*sat(dot(bs,float3(0.2126,0.7152,0.0722))*255.0,80.0,160.0);
            float3 tonedLab = float3(l.x,l.yz*(1.0-0.18*warm));
            float3 toned = max(invlab(tonedLab),float3(0.0));
            z = warm > 0.0 ? toned : z;
            float mx=max(z.r,max(z.g,z.b));
            float excess=max(mx-0.85,0.0);
            float mapped=0.85+0.149*excess/(excess+0.149);
            z *= mx>0.85 ? mapped/max(mx,1e-8) : 1.0;

            float y=dot(z,float3(0.2126,0.7152,0.0722));
            float by=dot(be,float3(0.2126,0.7152,0.0722));
            float3 cn=z/max(y,1e-12), bn=be/max(by,1e-12);
            float3 cl=lab(cn), bl=lab(bn);
            float ch=length(cl.yz), bh=length(bl.yz);
            float hue=(atan(cl.z/(cl.y >= 0.0 ? max(cl.y,1e-20) : min(cl.y,-1e-20))) + (cl.y < 0.0 ? (cl.z >= 0.0 ? 3.141592653589793 : -3.141592653589793) : 0.0))*57.29577951308232;
            float chromaGate=sat(hue,15.0,30.0)*(1.0-sat(hue,75.0,95.0))*sat(y,0.025,0.15)*sat(ch,0.03,0.10)*(1.0-sat(max(bs.r,max(bs.g,bs.b)),0.88,0.995))*sat(ch-bh,0.002,0.025);
            float weight=0.45*chromaGate;
            float3 outc=mix(z,bn*y,weight);
            outc += y-dot(outc,float3(0.2126,0.7152,0.0722));
            float3 delta=outc-y;
            float3 bound = float3(
                delta.r > 0.0 ? (1.0-y)/max(delta.r,1e-30) : (delta.r < 0.0 ? y/max(-delta.r,1e-30) : 1.0),
                delta.g > 0.0 ? (1.0-y)/max(delta.g,1e-30) : (delta.g < 0.0 ? y/max(-delta.g,1e-30) : 1.0),
                delta.b > 0.0 ? (1.0-y)/max(delta.b,1e-30) : (delta.b < 0.0 ? y/max(-delta.b,1e-30) : 1.0));
            float limit=clamp(min(bound.r,min(bound.g,bound.b)),0.0,1.0);
            outc=y+delta*limit;
            outc=weight>0.0 ? outc : z;
            return vec4(outc,1.0);
        }
    """#)
}
