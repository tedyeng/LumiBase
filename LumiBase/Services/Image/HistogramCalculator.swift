import Foundation
import AppKit
import Accelerate

/// Represents 256-bin normalized histogram data for RGB and Luminance channels
public struct HistogramData: Sendable {
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]
    public let luminance: [Float]
    
    public static let empty = HistogramData(
        red: Array(repeating: 0, count: 256),
        green: Array(repeating: 0, count: 256),
        blue: Array(repeating: 0, count: 256),
        luminance: Array(repeating: 0, count: 256)
    )
}

/// Computes hardware-accelerated RGB and Luminance histograms
public final class HistogramCalculator: Sendable {
    
    /// Computes 256-bin histogram from an NSImage
    public static func computeHistogram(for image: NSImage) async -> HistogramData {
        return await Task.detached(priority: .utility) { () -> HistogramData in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return .empty
            }
            
            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else { return .empty }
            
            // Downsample for ultra-fast histogram calculation if large
            let sampleWidth = min(width, 512)
            let sampleHeight = min(height, 512)
            
            var rawData = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerPixel = 4
            let bytesPerRow = bytesPerPixel * sampleWidth
            let bitsPerComponent = 8
            
            guard let context = CGContext(
                data: &rawData,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return .empty
            }
            
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            
            var rBins = [UInt](repeating: 0, count: 256)
            var gBins = [UInt](repeating: 0, count: 256)
            var bBins = [UInt](repeating: 0, count: 256)
            var lBins = [UInt](repeating: 0, count: 256)
            
            let pixelCount = sampleWidth * sampleHeight
            for i in 0..<pixelCount {
                let offset = i * 4
                let r = Int(rawData[offset])
                let g = Int(rawData[offset + 1])
                let b = Int(rawData[offset + 2])
                
                rBins[r] += 1
                gBins[g] += 1
                bBins[b] += 1
                
                // Rec.709 Luminance: 0.2126 R + 0.7152 G + 0.0722 B
                let lum = Int(round(0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)))
                let clampedLum = max(0, min(255, lum))
                lBins[clampedLum] += 1
            }
            
            // Exclude extreme clipped edges (bins 0 and 255) when computing peak height,
            // so single-color borders or clipped spikes do not flatten the entire histogram curve.
            let effectiveMax = max(1, max(
                rBins[1..<255].max() ?? 1,
                gBins[1..<255].max() ?? 1,
                bBins[1..<255].max() ?? 1,
                lBins[1..<255].max() ?? 1
            ))
            
            // Apply calibrated perceptual scaling (Lightroom power curve + 3-point smoothing)
            let power = 0.70
            func normalizeAndSmooth(_ bins: [UInt]) -> [Float] {
                let raw = bins.map { min(1.0, Float(pow(Double($0) / Double(effectiveMax), power))) }
                var smoothed = raw
                for i in 1..<255 {
                    smoothed[i] = (raw[i-1] * 0.22) + (raw[i] * 0.56) + (raw[i+1] * 0.22)
                }
                return smoothed
            }
            
            let normR = normalizeAndSmooth(rBins)
            let normG = normalizeAndSmooth(gBins)
            let normB = normalizeAndSmooth(bBins)
            let normL = normalizeAndSmooth(lBins)
            
            return HistogramData(red: normR, green: normG, blue: normB, luminance: normL)
        }.value
    }
}
