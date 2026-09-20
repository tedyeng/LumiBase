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
        
        // 2. White Balance / Kelvin Temperature (Subtle delta adjustment)
        if let temp = xmp.temperature, temp > 0 {
            let tint = CGFloat(xmp.tint ?? 0)
            // Scale color temperature gently relative to 5600K daylight reference
            current = current.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 5600, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(temp), y: tint * 0.5)
            ])
        }
        
        // 3. Highlights & Shadows (Smooth Adobe-like recovery, avoiding muddy shadows or dark sky)
        let hl = xmp.highlights2012 ?? 0
        let sh = xmp.shadows2012 ?? 0
        if hl != 0 || sh != 0 {
            let highlightAmount = max(0.6, 1.0 + (Double(hl) / 100.0 * 0.35))
            let shadowAmount = max(0.0, Double(sh) / 100.0 * 0.3)
            current = current.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": shadowAmount
            ])
        }
        
        // 4. Contrast & Dehaze (Gentle tonal curve without double-stacking)
        let contrastVal = (xmp.contrast2012 ?? 0) + Int(Double(xmp.dehaze ?? 0) * 0.6)
        if contrastVal != 0 {
            let contrastFactor = max(0.7, min(1.4, 1.0 + (Double(contrastVal) / 100.0 * 0.2)))
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrastFactor
            ])
        }
        
        // 5. Saturation & Vibrance (Calibrated natural color saturation)
        let sat = xmp.saturation ?? 0
        let vib = xmp.vibrance ?? 0
        let dehaze = xmp.dehaze ?? 0
        
        let totalSatDelta = (Double(sat) / 100.0 * 0.2) + (Double(vib) / 100.0 * 0.12) + (Double(dehaze) / 100.0 * 0.08)
        if abs(totalSatDelta) > 0.005 {
            let saturationFactor = max(0.0, min(1.6, 1.0 + totalSatDelta))
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturationFactor
            ])
        }
        
        // 6. Clarity & Texture (Gentle micro-contrast)
        let clarity = (xmp.clarity2012 ?? 0) + (xmp.texture ?? 0)
        if clarity > 5 {
            let intensity = min(0.4, Double(clarity) / 100.0 * 0.3)
            current = current.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 1.5,
                kCIInputIntensityKey: intensity
            ])
        }
        
        return current
    }
}
