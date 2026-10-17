import Foundation
import CoreGraphics

/// Represents a single control point on a Tone Curve, with coordinates in [0, 255]
public struct ToneCurvePoint: Codable, Equatable, Sendable, Comparable {
    public var x: Double // 0 to 255
    public var y: Double // 0 to 255
    
    public init(x: Double, y: Double) {
        self.x = max(0, min(255, x))
        self.y = max(0, min(255, y))
    }
    
    public static func < (lhs: ToneCurvePoint, rhs: ToneCurvePoint) -> Bool {
        lhs.x < rhs.x
    }
}

/// Represents Lightroom Classic Point Curves for Master (RGB), Red, Green, and Blue channels
public struct ToneCurveData: Codable, Equatable, Sendable {
    public var rgbPoints: [ToneCurvePoint]
    public var redPoints: [ToneCurvePoint]
    public var greenPoints: [ToneCurvePoint]
    public var bluePoints: [ToneCurvePoint]
    
    public init(
        rgbPoints: [ToneCurvePoint] = Self.linearPoints,
        redPoints: [ToneCurvePoint] = Self.linearPoints,
        greenPoints: [ToneCurvePoint] = Self.linearPoints,
        bluePoints: [ToneCurvePoint] = Self.linearPoints
    ) {
        self.rgbPoints = rgbPoints
        self.redPoints = redPoints
        self.greenPoints = greenPoints
        self.bluePoints = bluePoints
    }
    
    // MARK: - Built-in Presets
    
    public static let linearPoints: [ToneCurvePoint] = [
        ToneCurvePoint(x: 0, y: 0),
        ToneCurvePoint(x: 255, y: 255)
    ]
    
    public static let mediumContrastPoints: [ToneCurvePoint] = [
        ToneCurvePoint(x: 0, y: 0),
        ToneCurvePoint(x: 32, y: 22),
        ToneCurvePoint(x: 64, y: 56),
        ToneCurvePoint(x: 128, y: 128),
        ToneCurvePoint(x: 192, y: 196),
        ToneCurvePoint(x: 255, y: 255)
    ]
    
    public static let strongContrastPoints: [ToneCurvePoint] = [
        ToneCurvePoint(x: 0, y: 0),
        ToneCurvePoint(x: 32, y: 16),
        ToneCurvePoint(x: 64, y: 50),
        ToneCurvePoint(x: 128, y: 128),
        ToneCurvePoint(x: 192, y: 202),
        ToneCurvePoint(x: 255, y: 255)
    ]
    
    public static let linear = ToneCurveData()
    public static let mediumContrast = ToneCurveData(rgbPoints: mediumContrastPoints)
    public static let strongContrast = ToneCurveData(rgbPoints: strongContrastPoints)
    
    public var isLinear: Bool {
        rgbPoints == Self.linearPoints &&
        redPoints == Self.linearPoints &&
        greenPoints == Self.linearPoints &&
        bluePoints == Self.linearPoints
    }
    
    public var cacheIdentity: String {
        guard !isLinear else { return "0" }
        func pts(_ points: [ToneCurvePoint]) -> String {
            points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: ";")
        }
        return "rgb[\(pts(rgbPoints))]r[\(pts(redPoints))]g[\(pts(greenPoints))]b[\(pts(bluePoints))]"
    }
    
    // MARK: - Natural Cubic Spline Interpolation
    
    /// Evaluates 256 discrete lookup table values [0, 255] -> [0.0, 1.0] from control points using a natural cubic spline
    public static func evaluateLUT(for points: [ToneCurvePoint]) -> [Float] {
        let sorted = points.sorted()
        guard sorted.count >= 2 else {
            return (0...255).map { Float($0) / 255.0 }
        }
        
        let n = sorted.count
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            x[i] = sorted[i].x / 255.0
            y[i] = sorted[i].y / 255.0
        }
        
        // Natural Cubic Spline second derivatives
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = max(1e-5, x[i + 1] - x[i])
        }
        
        var alpha = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            alpha[i] = (3.0 / h[i] * (y[i + 1] - y[i])) - (3.0 / h[i - 1] * (y[i] - y[i - 1]))
        }
        
        var l = [Double](repeating: 0, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)
        l[0] = 1.0
        
        for i in 1..<(n - 1) {
            l[i] = 2.0 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1]
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }
        l[n - 1] = 1.0
        
        var c = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n - 1)
        var d = [Double](repeating: 0, count: n - 1)
        var a = [Double](repeating: 0, count: n)
        for i in 0..<n { a[i] = y[i] }
        
        for j in stride(from: n - 2, through: 0, by: -1) {
            c[j] = z[j] - mu[j] * c[j + 1]
            b[j] = (a[j + 1] - a[j]) / h[j] - h[j] * (c[j + 1] + 2.0 * c[j]) / 3.0
            d[j] = (c[j + 1] - c[j]) / (3.0 * h[j])
        }
        
        var lut = [Float](repeating: 0, count: 256)
        var currentInterval = 0
        
        for i in 0...255 {
            let u = Double(i) / 255.0
            
            while currentInterval < n - 2 && u > x[currentInterval + 1] {
                currentInterval += 1
            }
            
            let dx = u - x[currentInterval]
            let val = a[currentInterval] + b[currentInterval] * dx + c[currentInterval] * dx * dx + d[currentInterval] * dx * dx * dx
            lut[i] = Float(max(0.0, min(1.0, val)))
        }
        
        return lut
    }
}
