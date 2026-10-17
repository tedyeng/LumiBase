import AppKit
import CoreImage
import Foundation

/// High-performance CoreImage Metal kernel for 8-Band HSL Color Mixer
public enum ColorMixerKernel {
    private static let kernel = CIColorKernel(source: """
        float bandWeight(float h, float center, float width) {
            float d = abs(h - center);
            if (d > 180.0) { d = 360.0 - d; }
            return max(0.0, 1.0 - d / width);
        }

        kernel vec4 hslColorMixer(__sample s,
                                  vec3 rAdj, vec3 oAdj, vec3 yAdj, vec3 gAdj,
                                  vec3 aAdj, vec3 bAdj, vec3 pAdj, vec3 mAdj) {
            vec3 rgb = clamp(s.rgb, 0.0, 1.0);
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
            
            float sat = delta / maxC;
            float val = maxC;
            
            float wR = bandWeight(h, 0.0, 25.0) + bandWeight(h, 360.0, 25.0);
            float wO = bandWeight(h, 30.0, 20.0);
            float wY = bandWeight(h, 60.0, 20.0);
            float wG = bandWeight(h, 120.0, 40.0);
            float wA = bandWeight(h, 180.0, 45.0);
            float wB = bandWeight(h, 215.0, 55.0);
            float wP = bandWeight(h, 280.0, 40.0);
            float wM = bandWeight(h, 325.0, 30.0);
            
            float sumW = wR + wO + wY + wG + wA + wB + wP + wM;
            if (sumW < 1e-4) {
                return s;
            }
            
            float satDelta = (wR * rAdj.y + wO * oAdj.y + wY * yAdj.y + wG * gAdj.y +
                              wA * aAdj.y + wB * bAdj.y + wP * pAdj.y + wM * mAdj.y) / 100.0;
            float lumDelta = (wR * rAdj.z + wO * oAdj.z + wY * yAdj.z + wG * gAdj.z +
                              wA * aAdj.z + wB * bAdj.z + wP * pAdj.z + wM * mAdj.z) / 100.0;
            float hueShift = (wR * rAdj.x + wO * oAdj.x + wY * yAdj.x + wG * gAdj.x +
                              wA * aAdj.x + wB * bAdj.x + wP * pAdj.x + wM * mAdj.x) * 0.50;
            
            float newH = h + hueShift;
            if (newH < 0.0) { newH += 360.0; }
            if (newH >= 360.0) { newH -= 360.0; }
            
            float newSat = clamp(sat * (1.0 + satDelta), 0.0, 1.0);
            float newVal = clamp(val * (1.0 + lumDelta * 0.50 * sat), 0.0, 1.0);
            
            float c = newVal * newSat;
            float hSector = newH / 60.0;
            float x = c * (1.0 - abs(mod(hSector, 2.0) - 1.0));
            float m = newVal - c;
            
            vec3 outRgb = vec3(m);
            if (hSector < 1.0) {
                outRgb += vec3(c, x, 0.0);
            } else if (hSector < 2.0) {
                outRgb += vec3(x, c, 0.0);
            } else if (hSector < 3.0) {
                outRgb += vec3(0.0, c, x);
            } else if (hSector < 4.0) {
                outRgb += vec3(0.0, x, c);
            } else if (hSector < 5.0) {
                outRgb += vec3(x, 0.0, c);
            } else {
                outRgb += vec3(c, 0.0, x);
            }
            
            return vec4(clamp(outRgb, 0.0, 1.0), s.a);
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
