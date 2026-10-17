import AppKit
import CoreImage
import Foundation

/// High-performance CoreImage Metal kernel for 8-Band HSL Color Mixer
public enum ColorMixerKernel {
    private static let kernel = CIColorKernel(source: """
        float bandWeight(float h, float center, float width) {
            float d = abs(h - center);
            if (d > 180.0) { d = 360.0 - d; }
            float t = clamp(1.0 - d / width, 0.0, 1.0);
            return t * t * (3.0 - 2.0 * t);
        }

        kernel vec4 hslColorMixer(__sample s,
                                  vec3 rAdj, vec3 oAdj, vec3 yAdj, vec3 gAdj,
                                  vec3 aAdj, vec3 bAdj, vec3 pAdj, vec3 mAdj) {
            vec3 lin = max(s.rgb, vec3(0.0));
            vec3 rgb = sqrt(lin);
            
            float maxC = max(max(rgb.r, rgb.g), rgb.b);
            float minC = min(min(rgb.r, rgb.g), rgb.b);
            float delta = maxC - minC;
            
            if (delta < 1e-5 || maxC < 1e-5) {
                return s;
            }
            
            float h = 0.0;
            if (rgb.r >= maxC) {
                float seg = (rgb.g - rgb.b) / delta;
                h = 60.0 * (seg < 0.0 ? seg + 6.0 : seg);
            } else if (rgb.g >= maxC) {
                h = 60.0 * ((rgb.b - rgb.r) / delta + 2.0);
            } else {
                h = 60.0 * ((rgb.r - rgb.g) / delta + 4.0);
            }
            
            float sat = delta / max(maxC, 1e-5);
            float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
            
            float wR = bandWeight(h, 0.0, 15.0) + bandWeight(h, 360.0, 15.0);
            float wO = bandWeight(h, 24.0, 22.0);
            float wY = bandWeight(h, 55.0, 25.0);
            float wG = bandWeight(h, 120.0, 40.0);
            float wA = bandWeight(h, 180.0, 45.0);
            float wB = bandWeight(h, 215.0, 55.0);
            float wP = bandWeight(h, 280.0, 40.0);
            float wM = bandWeight(h, 325.0, 30.0);
            
            float sumW = wR + wO + wY + wG + wA + wB + wP + wM;
            if (sumW < 1e-4) {
                return s;
            }
            
            float norm = max(1.0, sumW);
            
            float hueShift = (wR * rAdj.x + wO * oAdj.x + wY * yAdj.x + wG * gAdj.x +
                              wA * aAdj.x + wB * bAdj.x + wP * pAdj.x + wM * mAdj.x) / norm * 0.50;
            float satDelta = (wR * rAdj.y + wO * oAdj.y + wY * yAdj.y + wG * gAdj.y +
                              wA * aAdj.y + wB * bAdj.y + wP * pAdj.y + wM * mAdj.y) / (norm * 100.0);
            float lumDelta = (wR * rAdj.z + wO * oAdj.z + wY * yAdj.z + wG * gAdj.z +
                              wA * aAdj.z + wB * bAdj.z + wP * pAdj.z + wM * mAdj.z) / (norm * 100.0);
            
            if (abs(hueShift) < 1e-4 && abs(satDelta) < 1e-4 && abs(lumDelta) < 1e-4) {
                return s;
            }
            
            vec3 outRgb = rgb;
            if (abs(hueShift) > 0.01) {
                float newH = h + hueShift;
                if (newH < 0.0) { newH += 360.0; }
                if (newH >= 360.0) { newH -= 360.0; }
                float c = delta;
                float hSector = newH / 60.0;
                float x = c * (1.0 - abs(mod(hSector, 2.0) - 1.0));
                vec3 chromaRgb = vec3(0.0);
                if (hSector < 1.0) { chromaRgb = vec3(c, x, 0.0); }
                else if (hSector < 2.0) { chromaRgb = vec3(x, c, 0.0); }
                else if (hSector < 3.0) { chromaRgb = vec3(0.0, c, x); }
                else if (hSector < 4.0) { chromaRgb = vec3(0.0, x, c); }
                else if (hSector < 5.0) { chromaRgb = vec3(x, 0.0, c); }
                else { chromaRgb = vec3(c, 0.0, x); }
                outRgb = vec3(minC) + chromaRgb;
                luma = dot(outRgb, vec3(0.299, 0.587, 0.114));
            }
            
            float satScale = max(0.0, 1.0 + satDelta);
            outRgb = mix(vec3(luma), outRgb, satScale);
            
            float lumWeight = clamp((sat - 0.04) * 2.5, 0.0, 1.0) * smoothstep(0.08, 0.32, luma);
            if (lumDelta >= 0.0) {
                float lift = clamp(lumDelta * 0.58 * lumWeight, 0.0, 0.65);
                outRgb = mix(outRgb, vec3(1.0), lift);
            } else {
                float darken = clamp(-lumDelta * 0.50 * lumWeight, 0.0, 0.65);
                outRgb = outRgb * (1.0 - darken);
            }
            
            vec3 outLin = max(outRgb, vec3(0.0));
            outLin = outLin * outLin;
            return vec4(outLin, s.a);
        }
    """)

    public static func apply(image: CIImage, hsl: HSLAdjustments) -> CIImage {
        guard let kernel, !hsl.isZero, !image.extent.isInfinite else { return image }
        
        func toVec(_ band: HSLBandAdjustment) -> CIVector {
            CIVector(x: CGFloat(band.hue), y: CGFloat(band.saturation), z: CGFloat(band.luminance))
        }
        
        let args: [Any] = [
            image,
            toVec(hsl.red),
            toVec(hsl.orange),
            toVec(hsl.yellow),
            toVec(hsl.green),
            toVec(hsl.aqua),
            toVec(hsl.blue),
            toVec(hsl.purple),
            toVec(hsl.magenta)
        ]
        
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }
}
