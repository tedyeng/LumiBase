import AppKit
import CoreImage
import Foundation

/// High-performance CoreImage Metal kernel for Tone Curves (Master RGB + Red + Green + Blue channels)
public enum ToneCurveKernel {
    private static let kernel = CIColorKernel(source: """
        float evalSpline9(float x, vec4 p0_3, vec4 p4_7, float p8) {
            float xc = clamp(x, 0.0, 1.0);
            float pos = xc * 8.0;
            float idx = clamp(floor(pos), 0.0, 7.0);
            float t = pos - idx;
            
            float y0, y1, y2, y3;
            if (idx < 0.5) {
                // Segment 0: [p0, p1]
                y1 = p0_3.x; y2 = p0_3.y; y0 = 2.0 * y1 - y2; y3 = p0_3.z;
            } else if (idx < 1.5) {
                // Segment 1: [p1, p2]
                y0 = p0_3.x; y1 = p0_3.y; y2 = p0_3.z; y3 = p0_3.w;
            } else if (idx < 2.5) {
                // Segment 2: [p2, p3]
                y0 = p0_3.y; y1 = p0_3.z; y2 = p0_3.w; y3 = p4_7.x;
            } else if (idx < 3.5) {
                // Segment 3: [p3, p4]
                y0 = p0_3.z; y1 = p0_3.w; y2 = p4_7.x; y3 = p4_7.y;
            } else if (idx < 4.5) {
                // Segment 4: [p4, p5]
                y0 = p0_3.w; y1 = p4_7.x; y2 = p4_7.y; y3 = p4_7.z;
            } else if (idx < 5.5) {
                // Segment 5: [p5, p6]
                y0 = p4_7.x; y1 = p4_7.y; y2 = p4_7.z; y3 = p4_7.w;
            } else if (idx < 6.5) {
                // Segment 6: [p6, p7]
                y0 = p4_7.y; y1 = p4_7.z; y2 = p4_7.w; y3 = p8;
            } else {
                // Segment 7: [p7, p8]
                y0 = p4_7.z; y1 = p4_7.w; y2 = p8; y3 = 2.0 * y2 - y1;
            }
            
            float val = 0.5 * ((2.0 * y1) +
                               (-y0 + y2) * t +
                               (2.0 * y0 - 5.0 * y1 + 4.0 * y2 - y3) * t * t +
                               (-y0 + 3.0 * y1 - 3.0 * y2 + y3) * t * t * t);
            return clamp(val, 0.0, 1.0);
        }

        kernel vec4 toneCurveMultiChannel(__sample s,
                                          vec4 rgb0_3, vec4 rgb4_7, float rgb8,
                                          vec4 r0_3, vec4 r4_7, float r8,
                                          vec4 g0_3, vec4 g4_7, float g8,
                                          vec4 b0_3, vec4 b4_7, float b8) {
            vec3 c = max(s.rgb, vec3(0.0));
            
            // 1. Master RGB Curve
            float rm = evalSpline9(c.r, rgb0_3, rgb4_7, rgb8);
            float gm = evalSpline9(c.g, rgb0_3, rgb4_7, rgb8);
            float bm = evalSpline9(c.b, rgb0_3, rgb4_7, rgb8);
            
            // 2. Individual Channel Curves
            float rOut = evalSpline9(rm, r0_3, r4_7, r8);
            float gOut = evalSpline9(gm, g0_3, g4_7, g8);
            float bOut = evalSpline9(bm, b0_3, b4_7, b8);
            
            return vec4(clamp(vec3(rOut, gOut, bOut), 0.0, 1.0), s.a);
        }
    """)

    public static func apply(image: CIImage, toneCurve: ToneCurveData) -> CIImage {
        guard let kernel, !toneCurve.isLinear, !image.extent.isInfinite else { return image }
        
        let lutRGB = ToneCurveData.evaluateLUT(for: toneCurve.rgbPoints)
        let lutR = ToneCurveData.evaluateLUT(for: toneCurve.redPoints)
        let lutG = ToneCurveData.evaluateLUT(for: toneCurve.greenPoints)
        let lutB = ToneCurveData.evaluateLUT(for: toneCurve.bluePoints)
        
        func extract9(_ lut: [Float]) -> (CIVector, CIVector, Float) {
            let v0_3 = CIVector(
                x: CGFloat(lut[0]),
                y: CGFloat(lut[32]),
                z: CGFloat(lut[64]),
                w: CGFloat(lut[96])
            )
            let v4_7 = CIVector(
                x: CGFloat(lut[128]),
                y: CGFloat(lut[160]),
                z: CGFloat(lut[192]),
                w: CGFloat(lut[224])
            )
            let v8 = Float(lut[255])
            return (v0_3, v4_7, v8)
        }
        
        let (rgb0_3, rgb4_7, rgb8) = extract9(lutRGB)
        let (r0_3, r4_7, r8) = extract9(lutR)
        let (g0_3, g4_7, g8) = extract9(lutG)
        let (b0_3, b4_7, b8) = extract9(lutB)
        
        let args: [Any] = [
            image,
            rgb0_3, rgb4_7, rgb8,
            r0_3, r4_7, r8,
            g0_3, g4_7, g8,
            b0_3, b4_7, b8
        ]
        
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }
}
