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
        baseHolder: BaseImageHolder? = nil,
        isRaw: Bool? = nil
    ) -> CIImage {
        guard let xmp = xmp else {
            return image
        }
        
        let isRaw = isRaw ?? (baseHolder?.isRaw ?? false)
        let hasDevelopEdits = xmp.hasDevelopEdits
        
        // If non-raw without develop edits, passthrough untouched
        if !isRaw && !hasDevelopEdits {
            return image
        }
        
        let useAdvancedRAWHighlights = isRaw && NativeHighlightsService.isAdvancedEnabled(for: xmp) && ((xmp.highlights2012 ?? 0) < 0 || xmp.advancedRAWHighlightRecovery == true)
        if isRaw && PerformanceSettings.currentRAWPipelineEngine == .darkroom && !useAdvancedRAWHighlights {
            return processDarkroom(image: image, xmp: xmp)
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
        
        // 3. Contrast (Lightroom PV2012 midtone punch with scene-adaptive pivot)
        let dehaze = Double(xmp.dehaze ?? 0)
        let contrastVal = Double(xmp.contrast2012 ?? 0)
        if contrastVal != 0 {
            let contrastFactor = max(0.55, min(1.75, 1.0 + (contrastVal / 100.0 * 0.42)))
            let pivot = AutoToneService.estimateContrastPivot(from: baseHolder)
            current = AdaptiveContrastKernel.apply(
                image: current,
                contrastFactor: Float(contrastFactor),
                pivot: Float(pivot)
            )
        }
        
        // 3b. Dehaze (Scale-invariant dark-channel atmospheric veil removal / mist)
        if dehaze != 0 {
            current = LocalDehazeKernel.apply(
                image: current,
                dehazeFactor: Float(dehaze / 100.0)
            )
        }
        
        // 4. Vibrance and Saturation (Color enrichment before tone luminosity mapping)
        let isBW = (xmp.convertToGrayscale == true) || (xmp.saturation == -100)
        let hl = Double(xmp.highlights2012 ?? 0)
        let hlFactor = hl / 100.0
        // Natural highlight desaturation: in Adobe PV2012, positive highlights roll off gently towards specular white
        let hlDesatScale = hlFactor > 0 ? max(0.80, 1.0 - (hlFactor * 0.20)) : 1.0
        
        if !isBW {
            let vib = Double(xmp.vibrance ?? 0)
            let totalVib = (vib / 100.0 * 0.80) * hlDesatScale
            if abs(totalVib) > 0.01 {
                current = current.applyingFilter("CIVibrance", parameters: [
                    "inputAmount": totalVib
                ])
            }
            
            // Saturation (-100 = 0.0 / Mono, 0 = 1.0 / Neutral, +100 = 2.0 / Vivid)
            let sat = Double(xmp.saturation ?? 0)
            let rawSat = 1.0 + ((sat / 100.0 * 0.40) * hlDesatScale)
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
        
        // 5a. Edge-preserving log-luminance local shadow recovery (Lightroom PV2012 / Camera Raw shadow decompression)
        if sh != 0 {
            current = LocalShadowRecoveryKernel.apply(
                image: current,
                shadowFactor: Float(shFactor),
                blacksFactor: Float(bFactor)
            )
        }
        
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

            // Decouple negative Blacks from quarter-tones (x = 0.25) when Shadows > 0 so Blacks anchors the toe without cancelling shadow recovery
            let effectiveBFactor = shFactor > 0 ? bFactor * (1.0 - 0.85 * shFactor) : bFactor
            let shCurveP1 = shFactor > 0 ? (shFactor * 0.02) : (shFactor * 0.06)
            let shCurveP2 = shFactor > 0 ? 0.0 : (shFactor * 0.03)

            let p0Y = max(0.0, min(0.04, 0.0 + (bFactor * 0.01)))
            let p1Y = max(0.12, min(0.35, 0.24 + hlP1 + shCurveP1 + (effectiveBFactor * 0.20)))
            let p2Y = max(0.40, min(0.65, 0.50 + hlP2 + shCurveP2))
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

        // 6. Color Mixer (8-Band HSL) - runs before B&W conversion so HSL Luminance acts as 8-band B&W Mix
        if !xmp.hsl.isZero {
            current = ColorMixerKernel.apply(image: current, hsl: xmp.hsl)
        }
        
        // 6b. Black & White Conversion (after Color Mixer so per-band luminance adjustments shape grayscale tones)
        if isBW {
            current = current.applyingFilter("CIPhotoEffectMono")
        }

        // 7. Point Tone Curves (RGB Master, Red, Green, Blue) - runs after HSL so per-channel curves aren't skewed by HSL
        if !xmp.toneCurve.isLinear {
            current = ToneCurveKernel.apply(image: current, toneCurve: xmp.toneCurve)
        }
        
        // 8. Texture (Scale-invariant fine detail: >0 Sharpen, <0 Skin Soften)
        if let texture = xmp.texture, texture != 0 {
            let longEdge = Double(max(current.extent.width, current.extent.height))
            let texRadius = max(1.2, 0.0008 * longEdge)
            if texture > 0 {
                let texIntensity = min(1.4, Double(texture) / 100.0 * 1.1)
                current = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: texRadius,
                    kCIInputIntensityKey: texIntensity
                ])
            } else {
                let softenFactor = Double(abs(texture)) / 100.0 * 0.50
                let blurred = current.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: texRadius * 1.25
                ]).cropped(to: current.extent)
                current = current.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred,
                    "inputTime": softenFactor
                ])
            }
        }
        
        // 8b. Clarity (Scale-invariant log-luminance midtone local contrast: >0 Punch, <0 Dreamy Glow)
        if let clarity = xmp.clarity2012, clarity != 0 {
            current = LocalClarityKernel.apply(image: current, clarityFactor: Float(Double(clarity) / 100.0))
        }
        
        // 8c. Spot Removal / Healing (in uncropped image space before Crop & Straighten)
        if !xmp.spotHeals.isEmpty {
            current = SpotHealKernel.apply(image: current, spots: xmp.spotHeals)
        }

        // 9. Crop and Straighten (Rotation & Crop Box)
        if xmp.hasCrop {
            current = applyCrop(image: current, xmp: xmp)
        }
        
        if isRaw && BaselineToneKernel.isEnabled {
            current = BaselineToneKernel.apply(current)
        }
        return current
    }

    /// Fast Metal CIRAWFilter pipeline matching darkroom (shutter-lab) 1:1 bit-for-bit
    public func processDarkroom(image: CIImage, xmp: XMPMetadata) -> CIImage {
        var current = image
        
        let hl = Double(xmp.highlights2012 ?? 0)
        let sh = Double(xmp.shadows2012 ?? 0)
        let whites = Double(xmp.whites2012 ?? 0)
        let blacks = Double(xmp.blacks2012 ?? 0)
        
        // 1. Optical Exposure Compensation (Reinhard highlight shoulder prevents positive EV from clipping highlights)
        let ev = Float(xmp.exposure2012 ?? 0.0)
        if abs(ev) > 0.001 {
            current = OpticalExposureKernel.apply(image: current, ev: ev, whites: Float(whites))
        }
        
        // 2. Highlights & Shadows
        if hl != 0 {
            let highlightAmount = max(0.6, 1.0 + (hl / 100.0 * 0.35))
            current = current.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": 0.0
            ])
        }
        if sh != 0 {
            current = LocalShadowRecoveryKernel.apply(
                image: current,
                shadowFactor: Float(sh / 100.0),
                blacksFactor: Float(blacks / 100.0)
            )
        }
        
        // 2b. Whites & Blacks (Dynamic Range Endpoints via CIToneCurve)
        if whites != 0 || blacks != 0 {
            let wFactor = whites / 100.0
            let bFactor = blacks / 100.0
            let shFactor = max(0.0, sh / 100.0)
            let effectiveBFactor = bFactor * (1.0 - 0.85 * shFactor)
            let p0Y = max(0.0, min(0.04, 0.0 + (bFactor * 0.01)))
            let p1Y = max(0.12, min(0.35, 0.25 + (effectiveBFactor * 0.15)))
            let p2Y = 0.50
            let p3Y = max(0.60, min(0.90, 0.75 + (wFactor * 0.10)))
            let p4Y = max(0.95, min(1.0, 1.0 + (wFactor * 0.03)))
            current = current.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p0Y),
                "inputPoint1": CIVector(x: 0.25, y: p1Y),
                "inputPoint2": CIVector(x: 0.50, y: p2Y),
                "inputPoint3": CIVector(x: 0.75, y: p3Y),
                "inputPoint4": CIVector(x: 1.0, y: p4Y)
            ])
        }
        
        // 3. Contrast (Perceptual S-curve contrast so positive Contrast never crushes linear shadows to 0)
        let contrast = Double(xmp.contrast2012 ?? 0)
        let dehaze = Double(xmp.dehaze ?? 0)
        if contrast != 0 {
            let contrastFactor = max(0.55, min(1.75, 1.0 + (contrast / 100.0 * 0.42)))
            current = AdaptiveContrastKernel.apply(
                image: current,
                contrastFactor: Float(contrastFactor),
                pivot: 0.50
            )
        }
        
        // 3b. Dehaze (Scale-invariant dark-channel atmospheric veil removal / mist)
        if dehaze != 0 {
            current = LocalDehazeKernel.apply(
                image: current,
                dehazeFactor: Float(dehaze / 100.0)
            )
        }
        
        // 4. Saturation & Vibrance
        let sat = Double(xmp.saturation ?? 0)
        let vib = Double(xmp.vibrance ?? 0)
        let totalSatDelta = (sat / 100.0 * 0.2) + (vib / 100.0 * 0.12)
        if abs(totalSatDelta) > 0.005 {
            let satFactor = max(0.0, min(1.6, 1.0 + totalSatDelta))
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: satFactor
            ])
        }
        
        // 4b. Color Mixer (8-Band HSL)
        if !xmp.hsl.isZero {
            current = ColorMixerKernel.apply(image: current, hsl: xmp.hsl)
        }
        
        // 5. Texture & Clarity (Scale-invariant fine detail and midtone local contrast)
        if let texture = xmp.texture, texture != 0 {
            let longEdge = Double(max(current.extent.width, current.extent.height))
            let texRadius = max(1.2, 0.0008 * longEdge)
            if texture > 0 {
                let texIntensity = min(1.4, Double(texture) / 100.0 * 1.1)
                current = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: texRadius,
                    kCIInputIntensityKey: texIntensity
                ])
            } else {
                let softenFactor = Double(abs(texture)) / 100.0 * 0.50
                let blurred = current.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: texRadius * 1.25
                ]).cropped(to: current.extent)
                current = current.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred,
                    "inputTime": softenFactor
                ])
            }
        }
        if let clarity = xmp.clarity2012, clarity != 0 {
            current = LocalClarityKernel.apply(image: current, clarityFactor: Float(Double(clarity) / 100.0))
        }
        
        // 6. Black & White
        let isBW = (xmp.convertToGrayscale == true) || (xmp.saturation == -100)
        if isBW {
            current = current.applyingFilter("CIPhotoEffectMono")
        }
        
        // 7. Point Tone Curves (if custom curves exist)
        if !xmp.toneCurve.isLinear {
            current = ToneCurveKernel.apply(image: current, toneCurve: xmp.toneCurve)
        }
        
        // 7b. Spot Removal / Healing (in uncropped image space before Crop & Straighten)
        if !xmp.spotHeals.isEmpty {
            current = SpotHealKernel.apply(image: current, spots: xmp.spotHeals)
        }

        // 8. Crop and Straighten
        if xmp.hasCrop {
            current = applyCrop(image: current, xmp: xmp)
        }
        
        return current
    }

    /// Crops and straightens an image using normalized XMP crop bounds and rotation
    public func applyCrop(image: CIImage, xmp: XMPMetadata) -> CIImage {
        var current = image
        let extent = current.extent
        guard !extent.isEmpty && extent.width > 0 && extent.height > 0 else {
            return current
        }
        
        // Angle / Straighten Rotation around image center.
        // CoreImage is Y-up (positive radians = CCW on screen), matching SwiftUI's Y-down .rotationEffect(.degrees(-angle)).
        let angleDeg = xmp.cropAngle ?? 0.0
        if abs(angleDeg) > 0.01 {
            let radians = CGFloat(angleDeg * .pi / 180.0)
            let centerX = extent.midX
            let centerY = extent.midY
            
            var transform = CGAffineTransform(translationX: centerX, y: centerY)
            transform = transform.rotated(by: radians)
            transform = transform.translatedBy(x: -centerX, y: -centerY)
            
            current = current.transformed(by: transform)
        }
        
        // Bounding Crop Box (normalized coordinates [0, 1])
        var top = CGFloat(xmp.cropTop ?? 0.0)
        var left = CGFloat(xmp.cropLeft ?? 0.0)
        var bottom = CGFloat(xmp.cropBottom ?? 1.0)
        var right = CGFloat(xmp.cropRight ?? 1.0)
        
        // If rotation angle is applied and no custom crop coordinates were explicitly specified,
        // automatically compute inner bounding crop box to eliminate black corners (matching darkroom CoreImageDecoder)
        if abs(angleDeg) > 0.01 && (top <= 0.001 && left <= 0.001 && bottom >= 0.999 && right >= 0.999) {
            let rad = CGFloat(abs(angleDeg) * .pi / 180.0)
            let sinA = sin(rad)
            let cosA = cos(rad)
            let aspect = extent.width / max(1.0, extent.height)
            let cropWNorm = 1.0 / (cosA + (1.0 / aspect) * sinA)
            let cropHNorm = 1.0 / (cosA + aspect * sinA)
            left = max(0.0, (1.0 - cropWNorm) / 2.0)
            right = min(1.0, 1.0 - left)
            top = max(0.0, (1.0 - cropHNorm) / 2.0)
            bottom = min(1.0, 1.0 - top)
        }
        
        if top > 0.001 || left > 0.001 || bottom < 0.999 || right < 0.999 {
            let cropX = extent.origin.x + (left * extent.width)
            let cropY = extent.origin.y + ((1.0 - bottom) * extent.height)
            let cropW = max(1.0, (right - left) * extent.width)
            let cropH = max(1.0, (bottom - top) * extent.height)
            let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            current = current.cropped(to: cropRect)
        }
        return current
    }
}


/// Scene-adaptive perceptual S-curve contrast kernel that pivots around an image-dependent midtone pivot [0.35, 0.65]
/// without subtracting a linear constant that would clip deep linear-sRGB shadows (< 0.015) to dead black.
public enum AdaptiveContrastKernel {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 adaptiveContrast(__sample s, float contrastFactor, float pivot) {
            vec3 c = max(s.rgb, vec3(0.0));
            if (abs(contrastFactor - 1.0) < 0.001) { return s; }
            
            float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float peak = max(c.r, max(c.g, c.b));
            float yMetric = max(y, 0.75 * peak);
            float yp = clamp(pow(yMetric, 1.0 / 2.2), 0.0, 1.0);
            float p = clamp(pivot * 0.75, 0.28, 0.50);
            
            float ypOut;
            if (yp <= p) {
                ypOut = p * pow(max(yp / p, 1e-6), contrastFactor);
            } else {
                ypOut = 1.0 - (1.0 - p) * pow(max((1.0 - yp) / (1.0 - p), 1e-6), contrastFactor);
            }
            
            float yMetricOut = pow(max(ypOut, 0.0), 2.2);
            vec3 outRgb = c * (yMetricOut / yMetric);
            
            float satLink = 1.0 + (contrastFactor - 1.0) * 0.35;
            float yOut = dot(outRgb, vec3(0.2126, 0.7152, 0.0722));
            outRgb = max(vec3(yOut) + (outRgb - vec3(yOut)) * satLink, vec3(0.0));
            return vec4(clamp(outRgb, 0.0, 1.0), s.a);
        }
    """)

    public static func apply(image: CIImage, contrastFactor: Float, pivot: Float) -> CIImage {
        guard let kernel, !image.extent.isInfinite else { return image }
        let clampedPivot = max(0.35, min(0.65, pivot))
        return kernel.apply(extent: image.extent, arguments: [image, contrastFactor, clampedPivot]) ?? image
    }
}

/// Edge-preserving log-luminance local shadow recovery kernel (Adobe Camera Raw PV2012 shadow decompression)
/// Uses a peak-aware log-luminance zone mask (zero halo across sharp sunlit/shadow ridges) paired with
/// a robust bilateral detail restorer so lifted RAW shadows retain full foliage and rock texture.
public enum LocalShadowRecoveryKernel {
    private static let packKernel = CIColorKernel(source: """
        kernel vec4 lsPackLogLuma(__sample s) {
            float y = max(dot(max(s.rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float l = log2(y / 0.18);
            return vec4(l, 0.0, 0.0, 1.0);
        }
    """)

    private static let applyKernel = CIColorKernel(source: """
        kernel vec4 localShadowRecovery(__sample s, __sample meanLog, float sh, float blacks) {
            vec3 c = max(s.rgb, vec3(0.0));
            if (abs(sh) < 0.001) { return s; }
            
            float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float peak = max(c.r, max(c.g, c.b));
            // Peak-aware shadow zone metric (protects saturated blue sky and warm sunlit highlights)
            float yZone = max(y, 0.68 * peak);
            float lZone = log2(yZone / 0.18);
            
            float l = log2(y / 0.18);
            float mu = meanLog.r;
            
            // Robust bilateral detail: restores local micro-contrast compressed by the shadow curve
            // for fine/medium textures (|d| < 0.7 stops) while vanishing to 0 across hard shadow boundaries
            float d = l - mu;
            float bilateralDetail = d * exp(-1.8 * d * d);
            
            float lNew;
            if (sh > 0.0) {
                // Strictly below middle gray (lZone < -0.18) so sky & highlights remain 100% untouched
                float ws = 1.0 - smoothstep(-1.65, -0.18, lZone);
                
                // Deep black floor guard modulated by negative Blacks to maintain a rich black anchor
                float toeFloor = -10.8 - min(0.0, blacks) * 1.6;
                float toeKnee  = -6.8  - min(0.0, blacks) * 1.4;
                float wToe = smoothstep(toeFloor, toeKnee, l);
                
                // Smooth log-domain shadow decompression evaluated on pixel lZone (zero spatial halo)
                float negL = min(lZone + 0.18, 0.0);
                float liftEV = sh * (-negL * 0.50 + 0.38) * ws * wToe;
                
                // Restore local contrast slope compressed by the shadow lift
                float detailRestore = sh * ws * wToe * 0.78 * bilateralDetail;
                lNew = l + liftEV + detailRestore;
            } else {
                float ws = 1.0 - smoothstep(-2.2, -0.18, lZone);
                lNew = l + sh * 1.15 * ws;
            }
            
            float gain = exp2(lNew - l);
            vec3 lifted = c * gain;
            
            // Natural shadow chroma preservation with deep-shadow color-noise guard
            if (sh > 0.0 && gain > 1.05) {
                float yOut = dot(lifted, vec3(0.2126, 0.7152, 0.0722));
                float deepNoiseGuard = smoothstep(-8.2, -5.2, l);
                float midShadowMask = 1.0 - smoothstep(-1.65, -0.18, lZone);
                float satScale = mix(0.88, 1.0 + 0.20 * sh * midShadowMask, deepNoiseGuard);
                lifted = max(vec3(yOut) + (lifted - vec3(yOut)) * satScale, vec3(0.0));
            }
            
            return vec4(clamp(lifted, 0.0, 1.0), s.a);
        }
    """)

    public static func apply(image: CIImage, shadowFactor: Float, blacksFactor: Float = 0.0) -> CIImage {
        let extent = image.extent
        guard abs(shadowFactor) >= 0.001,
              !extent.isEmpty, !extent.isInfinite,
              let packKernel, let applyKernel,
              let logLum = packKernel.apply(extent: extent, arguments: [image]) else {
            return image
        }
        
        let longEdge = max(extent.width, extent.height)
        let scale = min(1.0, 768.0 / max(longEdge, 1.0))
        let sigma = max(1.5, 0.008 * Double(longEdge * scale))
        
        let small = logLum.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let smallExtent = small.extent
        let blurredSmall = small
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: smallExtent)
        let meanLog = blurredSmall
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1.0 / scale, y: 1.0 / scale))
            .cropped(to: extent)
        
        return applyKernel.apply(
            extent: extent,
            arguments: [image, meanLog, shadowFactor, blacksFactor]
        ) ?? image
    }
}

/// Resolution-independent, edge-preserving log-luminance midtone local contrast kernel (Lightroom PV2012 Clarity).
/// Computes band-pass log-luminance detail at ~1.4% of the image long edge so Clarity behaves identically
/// across 1440px interactive proxies, 2560px display proxies, and 7000px+ full-resolution RAW images.
public enum LocalClarityKernel {
    private static let packKernel = CIColorKernel(source: """
        kernel vec4 lcPackLogLuma(__sample s) {
            float y = max(dot(max(s.rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float l = log2(y / 0.18);
            return vec4(l, 0.0, 0.0, 1.0);
        }
    """)

    private static let applyKernel = CIColorKernel(source: """
        kernel vec4 localClarity(__sample s, __sample meanLog, float clarity) {
            vec3 c = max(s.rgb, vec3(0.0));
            if (abs(clarity) < 0.001) { return s; }
            
            float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float l = log2(y / 0.18);
            float mu = meanLog.r;
            
            // Edge-preserving bilateral band-pass detail: strong on mid-frequency textures, tapers across hard macro edges
            float d = l - mu;
            float bilateralDetail = d * exp(-0.85 * d * d);
            
            // Midtone zone weighting (active from upper shadows through upper midtones, tapering at extreme blacks & specular whites)
            float wMid = smoothstep(-6.2, -2.2, l) * (1.0 - 0.50 * smoothstep(0.8, 2.5, l));
            
            float strength = clarity > 0.0 ? (clarity * 1.45) : (clarity * 1.05);
            float deltaL = strength * wMid * bilateralDetail;
            float gain = clamp(exp2(deltaL), 0.25, 4.0);
            vec3 outRgb = c * gain;
            return vec4(clamp(outRgb, 0.0, 1.0), s.a);
        }
    """)

    public static func apply(image: CIImage, clarityFactor: Float) -> CIImage {
        let extent = image.extent
        guard abs(clarityFactor) >= 0.001,
              !extent.isEmpty, !extent.isInfinite,
              let packKernel, let applyKernel,
              let logLum = packKernel.apply(extent: extent, arguments: [image]) else {
            return image
        }
        
        let longEdge = max(extent.width, extent.height)
        let scale = min(1.0, 768.0 / max(longEdge, 1.0))
        let sigma = max(2.0, 0.014 * Double(longEdge * scale))
        
        let small = logLum.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let smallExtent = small.extent
        let blurredSmall = small
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: smallExtent)
        let meanLog = blurredSmall
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1.0 / scale, y: 1.0 / scale))
            .cropped(to: extent)
        
        return applyKernel.apply(
            extent: extent,
            arguments: [image, meanLog, clarityFactor]
        ) ?? image
    }
}

/// Resolution-independent dark-channel atmospheric Dehaze kernel (Lightroom PV2012 Dehaze).
/// Positive Dehaze removes the washed-out atmospheric veil proportional to the local dark channel
/// (`min(R, G, B)` in perceptual space) and restores midtone contrast & color purity without
/// crushing clean foreground shadows; negative Dehaze adds soft atmospheric mist.
public enum LocalDehazeKernel {
    private static let packKernel = CIColorKernel(source: """
        kernel vec4 ldPackDarkChannel(__sample s) {
            vec3 c = clamp(max(s.rgb, vec3(0.0)), 0.0, 1.0);
            vec3 cp = pow(c, vec3(1.0 / 2.2));
            float dark = min(cp.r, min(cp.g, cp.b));
            return vec4(dark, 0.0, 0.0, 1.0);
        }
    """)

    private static let applyKernel = CIColorKernel(source: """
        kernel vec4 localDehaze(__sample s, __sample hazeSample, float dehaze) {
            vec3 c = clamp(max(s.rgb, vec3(0.0)), 0.0, 1.0);
            if (abs(dehaze) < 0.001) { return s; }
            
            vec3 cp = pow(c, vec3(1.0 / 2.2));
            float dark = min(cp.r, min(cp.g, cp.b));
            float hazeMap = hazeSample.r;
            
            vec3 jP;
            if (dehaze > 0.0) {
                float d = clamp(dehaze, 0.0, 1.0);
                // Clamp blurred dark channel near pixel dark channel to prevent halos on dark/sky edges
                float veil = clamp(min(hazeMap, dark + 0.12), 0.0, 0.90);
                float t = max(1.0 - d * 0.72 * veil, 0.25);
                float airlight = 0.94;
                jP = clamp((cp - vec3(airlight * (1.0 - t))) / t, 0.0, 1.0);
                
                // Gentle perceptual S-curve punch & color purity restoration
                float y = dot(jP, vec3(0.2126, 0.7152, 0.0722));
                float yOut = clamp(0.5 + (y - 0.5) * (1.0 + d * 0.18), 0.0, 1.0);
                if (y > 1e-5) {
                    jP = clamp(jP * (yOut / y), 0.0, 1.0);
                }
                float yFinal = dot(jP, vec3(0.2126, 0.7152, 0.0722));
                jP = clamp(vec3(yFinal) + (jP - vec3(yFinal)) * (1.0 + d * 0.24), 0.0, 1.0);
            } else {
                float d = clamp(-dehaze, 0.0, 1.0);
                float mist = d * 0.55 * (0.45 + 0.55 * hazeMap);
                jP = mix(cp, vec3(0.92, 0.94, 0.97), mist);
                float yFinal = dot(jP, vec3(0.2126, 0.7152, 0.0722));
                jP = clamp(vec3(yFinal) + (jP - vec3(yFinal)) * (1.0 - d * 0.20), 0.0, 1.0);
            }
            
            vec3 outRgb = pow(clamp(jP, 0.0, 1.0), vec3(2.2));
            return vec4(outRgb, s.a);
        }
    """)

    public static func apply(image: CIImage, dehazeFactor: Float) -> CIImage {
        let extent = image.extent
        guard abs(dehazeFactor) >= 0.001,
              !extent.isEmpty, !extent.isInfinite,
              let packKernel, let applyKernel,
              let darkImg = packKernel.apply(extent: extent, arguments: [image]) else {
            return image
        }
        
        let longEdge = max(extent.width, extent.height)
        let scale = min(1.0, 768.0 / max(longEdge, 1.0))
        let sigma = max(3.0, 0.018 * Double(longEdge * scale))
        
        let smallDark = darkImg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurredSmall = smallDark
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: smallDark.extent)
        let hazeMap = blurredSmall
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1.0 / scale, y: 1.0 / scale))
            .cropped(to: extent)
        
        return applyKernel.apply(
            extent: extent,
            arguments: [image, hazeMap, dehazeFactor]
        ) ?? image
    }
}

/// Non-destructive Lightroom-style Spot Removal / Healing kernel (Heal = frequency-separated hole-masked
/// gradient interpolation + clean source texture; Clone = direct feathered copy).
/// Evaluates only a tight bounding patch per spot on Metal GPU for sub-millisecond 120fps interactivity.
public enum SpotHealKernel {
    private static let ringMaskKernel = CIColorKernel(source: """
        kernel vec4 shRingMask(__sample s, float cx, float cy, float radiusPx) {
            vec2 p = destCoord();
            float dist = distance(p, vec2(cx, cy));
            float w = smoothstep(radiusPx * 0.85, radiusPx * 1.15, dist);
            return vec4(s.rgb * w, w);
        }
    """)

    private static let healBlendKernel = CIColorKernel(source: """
        kernel vec4 shHealBlend(
            __sample target,
            __sample targetRingBlur,
            __sample source,
            __sample sourceBlur,
            float cx,
            float cy,
            float radiusPx,
            float feather,
            float opacity
        ) {
            vec2 p = destCoord();
            float dist = distance(p, vec2(cx, cy));
            float innerR = radiusPx * max(0.05, 1.0 - 0.55 * feather);
            float outerR = radiusPx * (1.0 + 0.45 * feather);
            float mask = (1.0 - smoothstep(innerR, outerR, dist)) * opacity;
            if (mask <= 0.0005) { return target; }
            
            vec3 bgColor = targetRingBlur.a > 1e-4 ? (targetRingBlur.rgb / targetRingBlur.a) : target.rgb;
            vec3 sourceHigh = source.rgb - sourceBlur.rgb;
            vec3 healed = clamp(bgColor + sourceHigh, 0.0, 1.0);
            vec3 outRgb = mix(target.rgb, healed, mask);
            return vec4(outRgb, target.a);
        }
    """)

    private static let cloneBlendKernel = CIColorKernel(source: """
        kernel vec4 shCloneBlend(
            __sample target,
            __sample source,
            float cx,
            float cy,
            float radiusPx,
            float feather,
            float opacity
        ) {
            vec2 p = destCoord();
            float dist = distance(p, vec2(cx, cy));
            float innerR = radiusPx * max(0.05, 1.0 - 0.55 * feather);
            float outerR = radiusPx * (1.0 + 0.45 * feather);
            float mask = (1.0 - smoothstep(innerR, outerR, dist)) * opacity;
            if (mask <= 0.0005) { return target; }
            return vec4(mix(target.rgb, source.rgb, mask), target.a);
        }
    """)

    public static func apply(image: CIImage, spots: [SpotHealEntry]) -> CIImage {
        let extent = image.extent
        guard !spots.isEmpty, !extent.isEmpty, !extent.isInfinite else { return image }

        var current = image
        for spot in spots {
            let radiusPx = max(2.0, Float(spot.radius * Double(extent.width)))
            let cx = Float(extent.origin.x + spot.targetX * Double(extent.width))
            let cy = Float(extent.origin.y + (1.0 - spot.targetY) * Double(extent.height))
            let sx = Float(extent.origin.x + spot.sourceX * Double(extent.width))
            let sy = Float(extent.origin.y + (1.0 - spot.sourceY) * Double(extent.height))

            let dx = CGFloat(cx - sx)
            let dy = CGFloat(cy - sy)

            let pad = ceil(CGFloat(radiusPx) * (1.5 + 0.5 * CGFloat(spot.feather)) + 16.0)
            let patchRect = CGRect(
                x: CGFloat(cx) - pad,
                y: CGFloat(cy) - pad,
                width: pad * 2.0,
                height: pad * 2.0
            ).intersection(extent)
            guard !patchRect.isEmpty else { continue }

            let targetPatch = current.cropped(to: patchRect)
            let sourcePatch = current
                .clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: patchRect)

            let healedPatch: CIImage?
            switch spot.mode {
            case .clone:
                healedPatch = cloneBlendKernel?.apply(
                    extent: patchRect,
                    arguments: [
                        targetPatch,
                        sourcePatch,
                        cx,
                        cy,
                        radiusPx,
                        Float(spot.feather),
                        Float(spot.opacity)
                    ]
                )
            case .heal:
                let sigma = max(2.0, Double(radiusPx) * 0.65)
                if let ringMasked = ringMaskKernel?.apply(
                    extent: patchRect,
                    arguments: [targetPatch, cx, cy, radiusPx]
                ) {
                    let targetRingBlur = ringMasked
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
                        .cropped(to: patchRect)
                    let sourceBlur = sourcePatch
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
                        .cropped(to: patchRect)
                    healedPatch = healBlendKernel?.apply(
                        extent: patchRect,
                        arguments: [
                            targetPatch,
                            targetRingBlur,
                            sourcePatch,
                            sourceBlur,
                            cx,
                            cy,
                            radiusPx,
                            Float(spot.feather),
                            Float(spot.opacity)
                        ]
                    )
                } else {
                    healedPatch = nil
                }
            }

            if let healedPatch {
                current = healedPatch.composited(over: current).cropped(to: extent)
            }
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
