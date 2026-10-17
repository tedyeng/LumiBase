import AppKit
import CoreImage
import Foundation

/// Calculated result of automatic tone adjustment modeled from Lightroom Classic PV2012 / PV15.4
public struct AutoToneResult: Sendable, Equatable {
    public let exposure: Double
    public let contrast: Int
    public let highlights: Int
    public let shadows: Int
    public let whites: Int
    public let blacks: Int
    public let vibrance: Int
    public let saturation: Int
    public let contrastPivot: Double

    public init(
        exposure: Double,
        contrast: Int,
        highlights: Int,
        shadows: Int,
        whites: Int,
        blacks: Int,
        vibrance: Int,
        saturation: Int,
        contrastPivot: Double = 0.50
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.vibrance = vibrance
        self.saturation = saturation
        self.contrastPivot = contrastPivot
    }
}

/// Calculated result of automatic white balance adjustment
public struct AutoWBResult: Sendable, Equatable {
    public let temperature: Int
    public let tint: Int

    public init(temperature: Int, tint: Int) {
        self.temperature = temperature
        self.tint = tint
    }
}

/// Reverse-engineered Auto Tone and Auto White Balance predictor based on Lightroom Classic PV2012 / PV15.4 corpus fits
public final class AutoToneService: Sendable {
    public static let shared = AutoToneService()
    
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    public init() {}
    
    // MARK: - Adaptive Contrast Pivot Estimation
    
    /// Computes the adaptive contrast pivot from a sorted luma distribution:
    /// Pivot = clamp(0.577 + 0.568 * MeanLuma - 0.689 * MiddleLuma, 0.35, 0.65)
    public static func calculateContrastPivot(meanLuma: Double, middleLuma: Double) -> Double {
        let rawPivot = 0.577 + (0.568 * meanLuma) - (0.689 * middleLuma)
        return max(0.35, min(0.65, rawPivot))
    }
    
    private static let pivotCacheLock = NSLock()
    private static var lastPivotImageID: ObjectIdentifier?
    private static var lastPivotValue: Double = 0.50
    
    /// Estimates the adaptive contrast pivot from a BaseImageHolder (cached per interactive CIImage instance for 120fps slider performance)
    public static func estimateContrastPivot(from baseHolder: BaseImageHolder?) -> Double {
        guard let interactive = baseHolder?.interactive else { return 0.50 }
        let id = ObjectIdentifier(interactive)
        pivotCacheLock.lock()
        if lastPivotImageID == id {
            let cached = lastPivotValue
            pivotCacheLock.unlock()
            return cached
        }
        pivotCacheLock.unlock()
        
        let computed = shared.estimateContrastPivot(from: interactive)
        pivotCacheLock.lock()
        lastPivotImageID = id
        lastPivotValue = computed
        pivotCacheLock.unlock()
        return computed
    }
    
    /// Estimates the adaptive contrast pivot directly from a CIImage
    public func estimateContrastPivot(from image: CIImage) -> Double {
        let (luma, _, _) = sampleImageMetrics(from: image, targetLongEdge: 64)
        guard !luma.isEmpty else { return 0.50 }
        var sum: Double = 0.0
        for v in luma { sum += Double(v) }
        let meanLuma = sum / Double(luma.count)
        let middleLuma = Double(percentile(luma, q: 0.50))
        return Self.calculateContrastPivot(meanLuma: meanLuma, middleLuma: middleLuma)
    }
    
    // MARK: - Auto Tone Estimation
    
    /// Predicts Lightroom Classic Auto Tone parameters from an unadjusted or base preview CIImage.
    public func estimateAutoTone(from image: CIImage) -> AutoToneResult {
        let (luma, peak, chroma) = sampleImageMetrics(from: image, targetLongEdge: 256)
        
        guard !luma.isEmpty else {
            return AutoToneResult(
                exposure: 0.0,
                contrast: 6,
                highlights: -30,
                shadows: 35,
                whites: 10,
                blacks: -10,
                vibrance: 15,
                saturation: 0,
                contrastPivot: 0.50
            )
        }
        
        // Percentiles & Mean
        var lumaSum: Double = 0.0
        for v in luma { lumaSum += Double(v) }
        let meanLuma = lumaSum / Double(luma.count)
        let l50 = Double(percentile(luma, q: 0.50))
        let pivot = Self.calculateContrastPivot(meanLuma: meanLuma, middleLuma: l50)
        
        let l40 = percentile(luma, q: 0.40)
        let l99 = percentile(luma, q: 0.99)
        let l90 = percentile(luma, q: 0.90)
        let l01 = percentile(luma, q: 0.01)
        
        let p25 = percentile(peak, q: 0.25)
        let p10 = percentile(peak, q: 0.10)
        let p998 = percentile(peak, q: 0.998)
        
        let c35 = percentile(chroma, q: 0.35)
        
        // 1. Exposure: 2.22 - 2.13 * L40 - 1.52 * L99 (EV)
        let rawExposure = 2.22 - (2.13 * l40) - (1.52 * l99)
        let clampedExposure = max(-5.0, min(5.0, Double(round(rawExposure * 100.0) / 100.0)))
        
        // 2. Highlights: -36 - 51.9 * L90 + 26.9 * P25
        let rawHighlights = -36.0 - (51.9 * l90) + (26.9 * p25)
        let clampedHighlights = Int(max(-100.0, min(0.0, round(rawHighlights))))
        
        // 3. Shadows: 54.4 - 41.5 * P10
        let rawShadows = 54.4 - (41.5 * p10)
        let clampedShadows = Int(max(0.0, min(100.0, round(rawShadows))))
        
        // 4. Whites: 67.5 - 52.2 * P99.8
        let rawWhites = 67.5 - (52.2 * p998)
        let clampedWhites = Int(max(-100.0, min(100.0, round(rawWhites))))
        
        // 5. Blacks: -38 - 1.86 * log2(max(1e-4, linearL01))
        let linearL01 = srgbToLinear(l01)
        let logVal = log2(max(1e-4, linearL01))
        let rawBlacks = -38.0 - (1.86 * logVal)
        let clampedBlacks = Int(max(-100.0, min(0.0, round(rawBlacks))))
        
        // 6. Contrast: fixed +6 in modern Lightroom Auto
        let contrast = 6
        
        // 7. Vibrance: fixed +15 in modern Lightroom Auto
        let vibrance = 15
        
        // 8. Saturation: 2.07 - 10.2 * C35 (varies between -4 and +3 in Adobe percent)
        let rawSaturation = 2.07 - (10.2 * c35)
        let clampedSaturation = Int(max(-100.0, min(100.0, round(rawSaturation))))
        
        return AutoToneResult(
            exposure: clampedExposure,
            contrast: contrast,
            highlights: clampedHighlights,
            shadows: clampedShadows,
            whites: clampedWhites,
            blacks: clampedBlacks,
            vibrance: vibrance,
            saturation: clampedSaturation,
            contrastPivot: pivot
        )
    }
    
    // MARK: - Auto White Balance Estimation
    
    /// Predicts Auto White Balance using Gray World with Lightroom mired and tint compensation.
    public func estimateAutoWB(from image: CIImage) -> AutoWBResult {
        let (rVals, gVals, bVals) = sampleRGBValidPixels(from: image, targetLongEdge: 256)
        
        guard rVals.count >= 16 else {
            return AutoWBResult(temperature: 5500, tint: 10)
        }
        
        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        let count = Double(rVals.count)
        
        for i in 0..<rVals.count {
            sumR += Double(rVals[i])
            sumG += Double(gVals[i])
            sumB += Double(bVals[i])
        }
        
        let avgR = sumR / count
        let avgG = sumG / count
        let avgB = sumB / count
        
        guard avgR > 1e-4, avgG > 1e-4, avgB > 1e-4 else {
            return AutoWBResult(temperature: 5500, tint: 10)
        }
        
        // Gray World estimated mired from R/B ratio relative to D55 (5500K)
        let miredD55: Double = 1_000_000.0 / 5500.0
        let rToBRatio = avgR / avgB
        let estMired = miredD55 + ((rToBRatio - 1.0) * 110.0)
        
        // Lightroom Classic Auto WB offset: 23 mired warmer and -3 tint
        let finalMired = max(1_000_000.0 / 7500.0, min(1_000_000.0 / 2850.0, estMired - 23.0))
        let finalKelvin = Int(round(1_000_000.0 / finalMired))
        
        let gDeviation = (avgG - ((avgR + avgB) * 0.5)) / avgG
        let estTint = (gDeviation * 80.0) + 10.0
        let finalTint = Int(max(-50, min(50, round(estTint - 3.0))))
        
        return AutoWBResult(
            temperature: max(2850, min(7500, finalKelvin)),
            tint: finalTint
        )
    }
    
    // MARK: - Helper Sampling Routines
    
    private func sampleImageMetrics(from image: CIImage, targetLongEdge: CGFloat) -> (luma: [Float], peak: [Float], chroma: [Float]) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return ([], [], []) }
        
        let scale = min(1.0, targetLongEdge / max(extent.width, extent.height))
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetRect = CGRect(x: 0, y: 0, width: max(1, Int(scaledImage.extent.width)), height: max(1, Int(scaledImage.extent.height)))
        
        let width = Int(targetRect.width)
        let height = Int(targetRect.height)
        let totalPixels = width * height
        guard totalPixels > 0 else { return ([], [], []) }
        
        var pixelBuffer = [UInt8](repeating: 0, count: totalPixels * 4)
        
        ciContext.render(
            scaledImage,
            toBitmap: &pixelBuffer,
            rowBytes: width * 4,
            bounds: targetRect,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        
        var luma = [Float]()
        luma.reserveCapacity(totalPixels)
        var peak = [Float]()
        peak.reserveCapacity(totalPixels)
        var chroma = [Float]()
        chroma.reserveCapacity(totalPixels)
        
        for i in 0..<totalPixels {
            let offset = i * 4
            let r = Float(pixelBuffer[offset]) / 255.0
            let g = Float(pixelBuffer[offset + 1]) / 255.0
            let b = Float(pixelBuffer[offset + 2]) / 255.0
            
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let mx = max(r, max(g, b))
            let mn = min(r, min(g, b))
            let c: Float = mx > 0.02 ? ((mx - mn) / mx) : 0.0
            
            luma.append(l)
            peak.append(mx)
            chroma.append(c)
        }
        
        luma.sort()
        peak.sort()
        chroma.sort()
        
        return (luma, peak, chroma)
    }
    
    private func sampleRGBValidPixels(from image: CIImage, targetLongEdge: CGFloat) -> (r: [Float], g: [Float], b: [Float]) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return ([], [], []) }
        
        let scale = min(1.0, targetLongEdge / max(extent.width, extent.height))
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetRect = CGRect(x: 0, y: 0, width: max(1, Int(scaledImage.extent.width)), height: max(1, Int(scaledImage.extent.height)))
        
        let width = Int(targetRect.width)
        let height = Int(targetRect.height)
        let totalPixels = width * height
        guard totalPixels > 0 else { return ([], [], []) }
        
        var pixelBuffer = [UInt8](repeating: 0, count: totalPixels * 4)
        
        ciContext.render(
            scaledImage,
            toBitmap: &pixelBuffer,
            rowBytes: width * 4,
            bounds: targetRect,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        
        var rVals = [Float]()
        var gVals = [Float]()
        var bVals = [Float]()
        
        for i in 0..<totalPixels {
            let offset = i * 4
            let r = Float(pixelBuffer[offset]) / 255.0
            let g = Float(pixelBuffer[offset + 1]) / 255.0
            let b = Float(pixelBuffer[offset + 2]) / 255.0
            
            let mx = max(r, max(g, b))
            // Discard blown-out highlights and noise floor
            if mx >= 0.02 && mx <= 0.98 {
                rVals.append(r)
                gVals.append(g)
                bVals.append(b)
            }
        }
        
        return (rVals, gVals, bVals)
    }
    
    private func percentile(_ sorted: [Float], q: Double) -> Float {
        guard !sorted.isEmpty else { return 0.0 }
        let idx = Int(round(Double(sorted.count - 1) * max(0.0, min(1.0, q))))
        return sorted[idx]
    }
    
    private func srgbToLinear(_ val: Float) -> Float {
        if val <= 0.04045 {
            return val / 12.92
        } else {
            return pow((val + 0.055) / 1.055, 2.4)
        }
    }
}
