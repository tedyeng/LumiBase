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
            
            // Normalize to [0.0, 1.0]
            let maxCount = max(1, max(
                rBins.max() ?? 1,
                gBins.max() ?? 1,
                bBins.max() ?? 1,
                lBins.max() ?? 1
            ))
            
            let normR = rBins.map { Float($0) / Float(maxCount) }
            let normG = gBins.map { Float($0) / Float(maxCount) }
            let normB = bBins.map { Float($0) / Float(maxCount) }
            let normL = lBins.map { Float($0) / Float(maxCount) }
            
            return HistogramData(red: normR, green: normG, blue: normB, luminance: normL)
        }.value
    }
}
