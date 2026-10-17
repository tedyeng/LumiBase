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
        
        // 1. Optical Exposure Compensation (Lightcraft-grade Optical Exposure & Reinhard Shoulder)
        // If RAW demosaicing already applied native EV, only apply the live delta
        let targetEV = xmp.exposure2012 ?? 0.0
        let baseEV = Double(baseHolder?.baseExposure ?? 0.0)
        let deltaEV = targetEV - baseEV
        if abs(deltaEV) > 0.005 {
            let whites = Double(xmp.whites2012 ?? 0)
            current = OpticalExposureKernel.apply(image: current, ev: Float(deltaEV), whites: Float(whites))
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
        
        let isRawImage = baseHolder?.isRaw ?? false
        let isAdvancedRaw = isRawImage && NativeHighlightsService.isAdvancedEnabled(for: xmp)
        
        // 5a. Tone curve highlight recovery
        // (LocalHighlightsOperator bypassed to restore natural cloud 3D volume and prevent muddy flattening)
        
        let hasToneEdits = (hl != 0) || (sh != 0) || (whites != 0) || (blacks != 0) || (dehaze != 0)
        if hasToneEdits {
            // For RAW files with Advanced RAW Highlight Recovery enabled, preserve calibrated weights for AcceptedHighlightsKernel parity;
            // for standard pipeline (RAW without Advanced Recovery or non-RAW files), apply full PV2012 highlight rolloff.
            let hlP1: Double
            let hlP2: Double
            let hlP3: Double
            let hlP4: Double
            
            if isAdvancedRaw {
                hlP1 = 0.0
                hlP2 = 0.0
                hlP3 = 0.0
                hlP4 = 0.0
            } else {
                if hlFactor < 0 {
                    // Highlights -100 rolls off the shoulder (p3) to recover cloud details,
                    // while preserving the White Point (p4 = 1.0) and midtones (p2 = 0.50),
                    // exactly matching Lightroom and Lightcraft!
                    hlP1 = 0.0
                    hlP2 = 0.0
                    hlP3 = hlFactor * 0.10
                    hlP4 = 0.0
                } else {
                    hlP1 = 0.0
                    hlP2 = 0.0
                    hlP3 = hlFactor * 0.12
                    hlP4 = 0.0
                }
            }

            let p0Y = max(0.0, min(0.04, 0.0 + (bFactor * 0.01)))
            let p1Y = max(0.12, min(0.35, 0.24 + hlP1 + (shFactor * 0.06) + (bFactor * 0.20)))
            let p2Y = max(0.40, min(0.65, 0.50 + hlP2 + (shFactor * 0.03)))
            let p3Y = max(0.60, min(0.90, 0.75 + hlP3 + (wFactor * 0.06)))
            let p4Y = max(0.95, min(1.0, 1.0 + (wFactor * 0.03) + hlP4))
            
            current = current.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p0Y),
                "inputPoint1": CIVector(x: 0.25, y: p1Y),
                "inputPoint2": CIVector(x: 0.50, y: p2Y),
                "inputPoint3": CIVector(x: 0.75, y: p3Y),
                "inputPoint4": CIVector(x: 1.0, y: p4Y)
            ])
            
            // 5b. Highlight Micro-Contrast Compensation (PV2012 Cloud Volume & Edge Contrast)
            // When highlights are pulled down (hlFactor < 0), inject adaptive micro-contrast in the
            // mid-to-high luminance zone, masked away from shadows/silhouettes to restore natural 3D depth.
            if !isAdvancedRaw && hlFactor < 0 {
                let maskLuma = current.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0.0),
                    "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0.0),
                    "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0.0),
                    "inputAVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0.0),
                    "inputBiasVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0)
                ]).applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0.0, y: 0.0),
                    "inputPoint1": CIVector(x: 0.15, y: 0.0),
                    "inputPoint2": CIVector(x: 0.30, y: 0.55),
                    "inputPoint3": CIVector(x: 0.55, y: 1.0),
                    "inputPoint4": CIVector(x: 1.0, y: 1.0)
                ])
                
                let microContrastIntensity = min(0.85, abs(hlFactor) * 0.75)
                let enhanced = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 32.0,
                    kCIInputIntensityKey: microContrastIntensity
                ])
                
                current = current.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputImageKey: enhanced,
                    kCIInputBackgroundImageKey: current,
                    kCIInputMaskImageKey: maskLuma
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
        
        // 9. Crop and Straighten (Rotation & Crop Box)
        if xmp.hasCrop {
            let extent = current.extent
            if !extent.isEmpty && extent.width > 0 && extent.height > 0 {
                // 9a. Angle / Straighten Rotation around image center
                let angleDeg = xmp.cropAngle ?? 0.0
                if abs(angleDeg) > 0.01 {
                    let radians = CGFloat(-angleDeg * .pi / 180.0)
                    let centerX = extent.midX
                    let centerY = extent.midY
                    
                    var transform = CGAffineTransform(translationX: centerX, y: centerY)
                    transform = transform.rotated(by: radians)
                    transform = transform.translatedBy(x: -centerX, y: -centerY)
                    
                    current = current.transformed(by: transform)
                }
                
                // 9b. Bounding Crop Box (normalized coordinates [0, 1])
                let top = CGFloat(xmp.cropTop ?? 0.0)
                let left = CGFloat(xmp.cropLeft ?? 0.0)
                let bottom = CGFloat(xmp.cropBottom ?? 1.0)
                let right = CGFloat(xmp.cropRight ?? 1.0)
                
                if top > 0.001 || left > 0.001 || bottom < 0.999 || right < 0.999 {
                    let cropX = extent.origin.x + (left * extent.width)
                    let cropY = extent.origin.y + ((1.0 - bottom) * extent.height)
                    let cropW = max(1.0, (right - left) * extent.width)
                    let cropH = max(1.0, (bottom - top) * extent.height)
                    let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                    current = current.cropped(to: cropRect)
                }
            }
        }
        
        if isRaw && BaselineToneKernel.isEnabled {
            current = BaselineToneKernel.apply(current)
        }
        return current
    }
}


/// Baseline dark/mid-tone correction measured against Lightroom (all-zero) and Sony JPEG references:
/// lifts L* by ~3 and scales chroma by ~0.8 in the L* 1..35 band, and by ~0.88 for L* > 45. Experimental; see docs/baseline-tone-correction-zhTW.md.
public enum BaselineToneKernel {
    static var isEnabled: Bool {
        if let e = ProcessInfo.processInfo.environment["LB_BASELINE_A"] { return e != "0" }
        return (UserDefaults.standard.object(forKey: "baselineToneCorrection") as? Bool) ?? true
    }
    private static func tune(_ k: String, _ d: Double) -> String {
        if let v = ProcessInfo.processInfo.environment[k], let x = Double(v) { return String(x) }
        return String(d)
    }
    private static let kernel = CIColorKernel(source: """
        float labF(float t) { return t > 0.008856 ? pow(t, 1.0/3.0) : 7.787 * t + 16.0/116.0; }
        float labFInv(float t) { float t3 = t*t*t; return t3 > 0.008856 ? t3 : (t - 16.0/116.0) / 7.787; }
        kernel vec4 baselineTone(__sample s, float lift, float chroma, float brightChroma) {
            vec3 lin = s.rgb;
            vec3 l = clamp(lin, 0.0, 1.0);
            float X = dot(l, vec3(0.4124, 0.3576, 0.1805)) / 0.95047;
            float Y = dot(l, vec3(0.2126, 0.7152, 0.0722));
            float Z = dot(l, vec3(0.0193, 0.1192, 0.9505)) / 1.08883;
            float fx = labF(X), fy = labF(Y), fz = labF(Z);
            float L = 116.0 * fy - 16.0;
            float w = smoothstep(1.0, 6.0, L) * (1.0 - smoothstep(18.0, 35.0, L));
            float wb = smoothstep(45.0, 75.0, L);
            if (w <= 0.0 && wb <= 0.0) { return s; }
            float a = 500.0 * (fx - fy) * (1.0 - (1.0 - chroma) * w) * (1.0 - (1.0 - brightChroma) * wb);
            float b = 200.0 * (fy - fz) * (1.0 - (1.0 - chroma) * w) * (1.0 - (1.0 - brightChroma) * wb);
            float L2 = L + lift * w;
            float fy2 = (L2 + 16.0) / 116.0;
            float fx2 = fy2 + a / 500.0;
            float fz2 = fy2 - b / 200.0;
            float X2 = labFInv(fx2) * 0.95047, Y2 = labFInv(fy2), Z2 = labFInv(fz2) * 1.08883;
            vec3 outLin = vec3(
                dot(vec3(X2, Y2, Z2), vec3( 3.2406, -1.5372, -0.4986)),
                dot(vec3(X2, Y2, Z2), vec3(-0.9689,  1.8758,  0.0415)),
                dot(vec3(X2, Y2, Z2), vec3( 0.0557, -0.2040,  1.0570)));
            return vec4(max(outLin, vec3(0.0)), s.a);
        }
    """)
    static func apply(_ image: CIImage) -> CIImage {
        guard let kernel, !image.extent.isInfinite else { return image }
        let lift = Float(tune("LB_BA_LIFT", 3.0)) ?? 3.0
        let chroma = Float(tune("LB_BA_CHROMA", 0.8)) ?? 0.8
        let bright = Float(tune("LB_BA_BRIGHT", 0.88)) ?? 0.88
        return kernel.apply(extent: image.extent, arguments: [image, lift, chroma, bright]) ?? image
    }
}
