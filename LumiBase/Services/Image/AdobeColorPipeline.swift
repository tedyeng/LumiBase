import Foundation
import CoreImage
import AppKit

/// Adobe Lightroom PV2012 Color Pipeline for 1:1 color and tone rendering
public final class AdobeColorPipeline: Sendable {
    public static let shared = AdobeColorPipeline()
    
    private let dcpManager = DCPProfileManager.shared
    
    public init() {}
    
    /// Processes a raw CIImage through the calibrated Adobe Camera Raw emulation pipeline
    public func process(
        image: CIImage,
        cameraModel: String?,
        xmp: XMPMetadata?
    ) -> CIImage {
        guard let xmp = xmp, xmp.hasDevelopEdits else {
            return image
        }
        
        var current = image
        
        // 1. Exposure Compensation (EV)
        if let ev = xmp.exposure2012, ev != 0.0 {
            current = current.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: ev
            ])
        }
        
        // 2. White Balance / Kelvin Temperature & Tint (Lightroom Standard)
        if let temp = xmp.temperature, temp > 0 {
            let tint = CGFloat(xmp.tint ?? 0)
            // Higher Temp (>5500K) -> Warmer (amber/orange); Lower Temp (<5500K) -> Cooler (blue)
            // Positive Tint (>0) -> Magenta; Negative Tint (<0) -> Green
            current = current.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(temp), y: tint),
                "inputTargetNeutral": CIVector(x: 5500, y: 0)
            ])
        }
        
        // 3. Highlights & Shadows (Spatial local tone mapping)
        let hl = xmp.highlights2012 ?? 0
        let sh = xmp.shadows2012 ?? 0
        if hl < 0 || sh != 0 {
            // hl < 0: Apple bilateral highlight recovery (1.0 = neutral, 0.15 = maximum recovery)
            let highlightAmount = (hl < 0) ? max(0.0, 1.0 + (Double(hl) / 100.0 * 0.85)) : 1.0
            // sh: Shadow lifting (>0) or deepening (<0) with full -1.0...1.0 range
            let shadowAmount = max(-1.0, min(1.0, Double(sh) / 100.0 * 0.75))
            current = current.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": shadowAmount
            ])
        }
        
        // 4. Tone Curve (Highlights boost/compression, Shadows, Whites, Blacks & Dehaze)
        let whites = xmp.whites2012 ?? 0
        let blacks = xmp.blacks2012 ?? 0
        let dehaze = xmp.dehaze ?? 0
        let dehazeBlackDepth = Double(dehaze) / 100.0 * 0.04
        if hl != 0 || sh != 0 || whites != 0 || blacks != 0 || dehaze != 0 {
            let p0Y = max(0.0, min(0.25, 0.0 + (Double(blacks) / 100.0 * 0.08) - dehazeBlackDepth))
            let p1Y = max(0.10, min(0.40, 0.25 + (Double(sh) / 100.0 * 0.04) + (Double(blacks) / 100.0 * 0.04)))
            let p2Y = 0.50
            let p3Y = max(0.55, min(0.95, 0.75 + (Double(hl) / 100.0 * 0.10) + (Double(whites) / 100.0 * 0.05)))
            let p4Y = max(0.80, min(1.0, 1.0 + (Double(whites) / 100.0 * 0.08)))
            current = current.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p0Y),
                "inputPoint1": CIVector(x: 0.25, y: p1Y),
                "inputPoint2": CIVector(x: 0.5, y: p2Y),
                "inputPoint3": CIVector(x: 0.75, y: p3Y),
                "inputPoint4": CIVector(x: 1.0, y: p4Y)
            ])
        }
        
        // 5. Contrast & Dehaze Contrast
        let contrastVal = (xmp.contrast2012 ?? 0) + Int(Double(dehaze) * 0.35)
        if contrastVal != 0 {
            let contrastFactor = max(0.5, min(1.6, 1.0 + (Double(contrastVal) / 100.0 * 0.45)))
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrastFactor
            ])
        }
        
        // 6. Black & White or Vibrance & Saturation
        let isBW = (xmp.convertToGrayscale == true) || (xmp.saturation == -100)
        if isBW {
            current = current.applyingFilter("CIPhotoEffectMono")
        } else {
            // Vibrance (Nonlinear smart saturation preserving skin tones)
            if let vib = xmp.vibrance, vib != 0 {
                let vibAmount = Double(vib) / 100.0
                current = current.applyingFilter("CIVibrance", parameters: [
                    "inputAmount": vibAmount
                ])
            }
            
            // Saturation (-100 = 0.0 / Mono, 0 = 1.0 / Neutral, +100 = 2.0 / Vivid)
            let sat = xmp.saturation ?? 0
            let dehazeSatBoost = Double(dehaze) / 100.0 * 0.15
            let rawSat = 1.0 + (Double(sat) / 100.0) + dehazeSatBoost
            let saturationFactor = max(0.0, min(2.0, rawSat))
            if abs(saturationFactor - 1.0) > 0.005 {
                current = current.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: saturationFactor
                ])
            }
        }
        
        // 7. Texture (Fine Detail: >0 Sharpen, <0 Skin Soften)
        if let texture = xmp.texture, texture != 0 {
            if texture > 0 {
                let texIntensity = min(1.0, Double(texture) / 100.0 * 0.8)
                current = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 1.2,
                    kCIInputIntensityKey: texIntensity
                ])
            } else {
                let softenFactor = Double(abs(texture)) / 100.0 * 0.45
                let blurred = current.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 1.5
                ]).cropped(to: current.extent)
                current = current.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred,
                    "inputTime": softenFactor
                ])
            }
        }
        
        // 8. Clarity (Midtone Local Contrast: >0 Punch, <0 Dreamy Glow)
        if let clarity = xmp.clarity2012, clarity != 0 {
            if clarity > 0 {
                let clarIntensity = min(0.8, Double(clarity) / 100.0 * 0.6)
                current = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 12.0,
                    kCIInputIntensityKey: clarIntensity
                ])
            } else {
                let glowFactor = Double(abs(clarity)) / 100.0 * 0.40
                let blurred = current.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 10.0
                ]).cropped(to: current.extent)
                current = current.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred,
                    "inputTime": glowFactor
                ])
            }
        }
        
        return current
    }
}
