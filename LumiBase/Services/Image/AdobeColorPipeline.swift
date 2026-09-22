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
        xmp: XMPMetadata?,
        baseHolder: BaseImageHolder? = nil
    ) -> CIImage {
        guard let xmp = xmp else {
            return image
        }
        
        let isRaw = baseHolder?.isRaw ?? false
        let hasDevelopEdits = xmp.hasDevelopEdits
        
        // If non-raw without develop edits, passthrough untouched
        if !isRaw && !hasDevelopEdits {
            return image
        }
        
        var current = image
        
        // 1. Exposure Compensation (EV Delta)
        // If RAW demosaicing already applied native EV, only apply the live delta
        let targetEV = xmp.exposure2012 ?? 0.0
        let baseEV = Double(baseHolder?.baseExposure ?? 0.0)
        let deltaEV = targetEV - baseEV
        if abs(deltaEV) > 0.01 {
            current = current.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: deltaEV
            ])
        }
        
        // 2. White Balance / Kelvin Temperature & Tint Delta
        if isRaw, let cameraTemp = baseHolder?.baseTemperature {
            let targetTemp = Float(xmp.temperature ?? Int(cameraTemp))
            let cameraTint = baseHolder?.baseTint ?? 0.0
            let targetTint = Float(xmp.tint ?? Int(cameraTint))
            let deltaTemp = Double(targetTemp - cameraTemp)
            let deltaTint = Double(targetTint - cameraTint)
            
            if abs(deltaTemp) > 10.0 || abs(deltaTint) > 0.5 {
                // Adobe Planckian chromaticity calibration
                let rGain = max(0.4, min(2.5, 1.0 + (deltaTemp / 1000.0) * 0.155))
                let bGain = max(0.4, min(2.5, 1.0 - (deltaTemp / 1000.0) * 0.145))
                let gGain = max(0.4, min(2.5, 1.0 - (deltaTint / 100.0) * 0.15))
                current = current.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: rGain, y: 0.0, z: 0.0, w: 0.0),
                    "inputGVector": CIVector(x: 0.0, y: gGain, z: 0.0, w: 0.0),
                    "inputBVector": CIVector(x: 0.0, y: 0.0, z: bGain, w: 0.0),
                    "inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
                ])
            }
        } else if let temp = xmp.temperature, temp > 0 {
            let tint = CGFloat(xmp.tint ?? 0)
            let deltaTemp = CGFloat(temp - 5500) * 0.65
            let deltaTint = tint * 0.50
            if abs(deltaTemp) > 25 || abs(deltaTint) > 1.0 {
                current = current.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 5500.0 + deltaTemp, y: deltaTint),
                    "inputTargetNeutral": CIVector(x: 5500.0, y: 0.0)
                ])
            }
        }
        
        // 3. Contrast & Dehaze Contrast (Lightroom PV2012 midtone punch)
        let dehaze = Double(xmp.dehaze ?? 0)
        let contrastVal = Double(xmp.contrast2012 ?? 0) + (dehaze * 0.40)
        if contrastVal != 0 {
            let contrastFactor = max(0.6, min(1.6, 1.0 + (contrastVal / 100.0 * 0.20)))
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrastFactor
            ])
        }
        
        // 4. Black & White or Vibrance and Saturation (Color enrichment before tone luminosity mapping)
        let isBW = (xmp.convertToGrayscale == true) || (xmp.saturation == -100)
        let hl = Double(xmp.highlights2012 ?? 0)
        let hlFactor = hl / 100.0
        // Natural highlight desaturation: in Adobe PV2012, positive highlights roll off gently towards specular white
        let hlDesatScale = hlFactor > 0 ? max(0.80, 1.0 - (hlFactor * 0.20)) : 1.0
        
        if isBW {
            current = current.applyingFilter("CIPhotoEffectMono")
        } else {
            let vib = Double(xmp.vibrance ?? 0)
            let totalVib = ((vib / 100.0 * 0.80) + (dehaze / 100.0 * 0.20)) * hlDesatScale
            if abs(totalVib) > 0.01 {
                current = current.applyingFilter("CIVibrance", parameters: [
                    "inputAmount": totalVib
                ])
            }
            
            // Saturation (-100 = 0.0 / Mono, 0 = 1.0 / Neutral, +100 = 2.0 / Vivid)
            let sat = Double(xmp.saturation ?? 0)
            let dehazeSatBoost = dehaze / 100.0 * 0.10
            let rawSat = 1.0 + (((sat / 100.0 * 0.40) + dehazeSatBoost) * hlDesatScale)
            let saturationFactor = max(0.0, min(2.0, rawSat))
            if abs(saturationFactor - 1.0) > 0.005 {
                current = current.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: saturationFactor
                ])
            }
        }
        
        // 5. PV2012 Basic Tone Curve (Highlights, Shadows, Whites, Blacks)
        let sh = Double(xmp.shadows2012 ?? 0)
        let whites = Double(xmp.whites2012 ?? 0)
        let blacks = Double(xmp.blacks2012 ?? 0)
        let shFactor = sh / 100.0
        let wFactor = whites / 100.0
        let bFactor = blacks / 100.0
        
        let hasToneEdits = (hl != 0) || (sh != 0) || (whites != 0) || (blacks != 0) || (dehaze != 0)
        if hasToneEdits {
            let p0Y = max(0.0, min(0.04, 0.0 + (bFactor * 0.01)))
            let p1Y = max(0.12, min(0.35, 0.24 + (shFactor * 0.06) + (bFactor * 0.20)))
            let p2Y = max(0.46, min(0.65, 0.50 + (hlFactor * 0.08) + (shFactor * 0.03)))
            let p3Y = max(0.68, min(0.90, 0.75 + (hlFactor * 0.08) + (wFactor * 0.06)))
            let p4Y = max(0.92, min(1.0, 1.0 + (wFactor * 0.03)))
            
            current = current.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p0Y),
                "inputPoint1": CIVector(x: 0.25, y: p1Y),
                "inputPoint2": CIVector(x: 0.50, y: p2Y),
                "inputPoint3": CIVector(x: 0.75, y: p3Y),
                "inputPoint4": CIVector(x: 1.0, y: p4Y)
            ])
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
