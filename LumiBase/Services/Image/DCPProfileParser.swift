import Foundation
import CoreGraphics

/// Model representing a parsed Adobe DNG Camera Profile (.dcp)
public struct DCPProfile: Sendable {
    public let profileName: String
    public let uniqueCameraModel: String?
    public let calibrationIlluminant1: Int // 17 = StdA, 21 = D65
    public let calibrationIlluminant2: Int?
    public let colorMatrix1: [Double]? // 9 elements
    public let colorMatrix2: [Double]? // 9 elements
    public let forwardMatrix1: [Double]? // 9 elements
    public let forwardMatrix2: [Double]? // 9 elements
    public let toneCurve: [CGPoint]?
    
    public init(
        profileName: String,
        uniqueCameraModel: String?,
        calibrationIlluminant1: Int = 21,
        calibrationIlluminant2: Int? = 17,
        colorMatrix1: [Double]? = nil,
        colorMatrix2: [Double]? = nil,
        forwardMatrix1: [Double]? = nil,
        forwardMatrix2: [Double]? = nil,
        toneCurve: [CGPoint]? = nil
    ) {
        self.profileName = profileName
        self.uniqueCameraModel = uniqueCameraModel
        self.calibrationIlluminant1 = calibrationIlluminant1
        self.calibrationIlluminant2 = calibrationIlluminant2
        self.colorMatrix1 = colorMatrix1
        self.colorMatrix2 = colorMatrix2
        self.forwardMatrix1 = forwardMatrix1
        self.forwardMatrix2 = forwardMatrix2
        self.toneCurve = toneCurve
    }
    
    /// Computes the normalized 3x3 color matrix to convert camera RGB into sRGB space
    public func sRGBColorMatrix(for kelvin: Double) -> [Double]? {
        guard let fwd = interpolatedForwardMatrix(for: kelvin) else { return nil }
        
        // XYZ D50 to sRGB matrix (incorporating D50 -> D65 Bradford chromatic adaptation)
        let xyzD50TosRGB: [Double] = [
            3.1338561, -1.6168667, -0.4906146,
           -0.9787684,  1.9161415,  0.0334540,
            0.0719453, -0.2289914,  1.4052427
        ]
        
        var combined = [Double](repeating: 0.0, count: 9)
        for row in 0..<3 {
            for col in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += xyzD50TosRGB[row * 3 + k] * fwd[k * 3 + col]
                }
                combined[row * 3 + col] = sum
            }
        }
        
        // Row-normalize so white (1, 1, 1) maps exactly to (1, 1, 1) without white-point shift
        var normalized = [Double](repeating: 0.0, count: 9)
        for row in 0..<3 {
            let rowSum = combined[row * 3 + 0] + combined[row * 3 + 1] + combined[row * 3 + 2]
            if abs(rowSum) > 1e-6 {
                normalized[row * 3 + 0] = combined[row * 3 + 0] / rowSum
                normalized[row * 3 + 1] = combined[row * 3 + 1] / rowSum
                normalized[row * 3 + 2] = combined[row * 3 + 2] / rowSum
            } else {
                normalized[row * 3 + row] = 1.0
            }
        }
        return normalized
    }
    
    /// Computes the temperature-interpolated 3x3 ForwardMatrix for a given Kelvin temperature
    public func interpolatedForwardMatrix(for kelvin: Double) -> [Double]? {
        // If only one forward matrix exists, return it
        guard let fm1 = forwardMatrix1 else { return forwardMatrix2 }
        guard let fm2 = forwardMatrix2 else { return fm1 }
        
        // Temperatures of calibration illuminants
        // StdA (Illuminant 17) = 2856K, D65 (Illuminant 21) = 6504K, D50 (Illuminant 23) = 5000K
        let t1 = illuminantTemperature(calibrationIlluminant1)
        let t2 = illuminantTemperature(calibrationIlluminant2 ?? 21)
        
        if abs(t1 - t2) < 1.0 { return fm1 }
        
        // Adobe DNG Specification 1/T linear interpolation
        let invT = 1.0 / max(2000.0, min(12000.0, kelvin))
        let invT1 = 1.0 / t1
        let invT2 = 1.0 / t2
        
        let weight2 = max(0.0, min(1.0, (invT - invT1) / (invT2 - invT1)))
        let weight1 = 1.0 - weight2
        
        var result = [Double](repeating: 0.0, count: 9)
        for i in 0..<9 {
            result[i] = (fm1[i] * weight1) + (fm2[i] * weight2)
        }
        return result
    }
    
    private func illuminantTemperature(_ id: Int) -> Double {
        switch id {
        case 17: return 2856.0 // Standard Light A
        case 21: return 6504.0 // D65
        case 23: return 5000.0 // D50
        case 20: return 5500.0 // D55
        case 22: return 7500.0 // D75
        default: return 6504.0
        }
    }
}

/// High-performance TIFF/DNG binary parser for Adobe DCP files
public final class DCPProfileParser: Sendable {
    public static let shared = DCPProfileParser()
    
    public init() {}
    
    /// Parses an Adobe DCP file from a file URL
    public func parse(url: URL) -> DCPProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }
    
    /// Parses an Adobe DCP file from raw binary data
    public func parse(data: Data) -> DCPProfile? {
        guard data.count >= 16 else { return nil }
        
        let isLittleEndian = (data[0] == 0x49 && data[1] == 0x49)
        let isBigEndian = (data[0] == 0x4D && data[1] == 0x4D)
        guard isLittleEndian || isBigEndian else { return nil }
        
        let ifdOffset: UInt32 = isLittleEndian ?
            data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) } :
            UInt32(bigEndian: data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) })
        
        var offset = Int(ifdOffset)
        guard offset + 2 <= data.count else { return nil }
        
        let entryCount: UInt16 = isLittleEndian ?
            data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) } :
            UInt16(bigEndian: data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) })
        offset += 2
        
        var profileName = "Adobe Standard"
        var cameraModel: String? = nil
        var illum1: Int = 21
        var illum2: Int? = nil
        var cm1: [Double]? = nil
        var cm2: [Double]? = nil
        var fm1: [Double]? = nil
        var fm2: [Double]? = nil
        var toneCurve: [CGPoint]? = nil
        
        for _ in 0..<entryCount {
            guard offset + 12 <= data.count else { break }
            let tag: UInt16 = isLittleEndian ?
                data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) } :
                UInt16(bigEndian: data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) })
            let _ : UInt16 = isLittleEndian ?
                data.subdata(in: offset+2..<offset+4).withUnsafeBytes { $0.load(as: UInt16.self) } :
                UInt16(bigEndian: data.subdata(in: offset+2..<offset+4).withUnsafeBytes { $0.load(as: UInt16.self) })
            let count: UInt32 = isLittleEndian ?
                data.subdata(in: offset+4..<offset+8).withUnsafeBytes { $0.load(as: UInt32.self) } :
                UInt32(bigEndian: data.subdata(in: offset+4..<offset+8).withUnsafeBytes { $0.load(as: UInt32.self) })
            let valOrOffset: UInt32 = isLittleEndian ?
                data.subdata(in: offset+8..<offset+12).withUnsafeBytes { $0.load(as: UInt32.self) } :
                UInt32(bigEndian: data.subdata(in: offset+8..<offset+12).withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 12
            
            switch tag {
            case 0xc614: // UniqueCameraModel (50708)
                cameraModel = readString(data: data, count: Int(count), valOrOffset: Int(valOrOffset))
            case 0xc6f8: // ProfileName (50936)
                if let name = readString(data: data, count: Int(count), valOrOffset: Int(valOrOffset)) {
                    profileName = name
                }
            case 0xc65a: // CalibrationIlluminant1 (50778)
                illum1 = Int(valOrOffset & 0xFFFF)
            case 0xc65b: // CalibrationIlluminant2 (50779)
                illum2 = Int(valOrOffset & 0xFFFF)
            case 0xc621: // ColorMatrix1 (50721)
                cm1 = readMatrix(data: data, offset: Int(valOrOffset), isLittleEndian: isLittleEndian)
            case 0xc622: // ColorMatrix2 (50722)
                cm2 = readMatrix(data: data, offset: Int(valOrOffset), isLittleEndian: isLittleEndian)
            case 0xc714: // ForwardMatrix1 (50964)
                fm1 = readMatrix(data: data, offset: Int(valOrOffset), isLittleEndian: isLittleEndian)
            case 0xc715: // ForwardMatrix2 (50965)
                fm2 = readMatrix(data: data, offset: Int(valOrOffset), isLittleEndian: isLittleEndian)
            case 0xc6fc: // ProfileToneCurve (50940)
                toneCurve = readToneCurve(data: data, count: Int(count), offset: Int(valOrOffset), isLittleEndian: isLittleEndian)
            default:
                break
            }
        }
        
        return DCPProfile(
            profileName: profileName,
            uniqueCameraModel: cameraModel,
            calibrationIlluminant1: illum1,
            calibrationIlluminant2: illum2,
            colorMatrix1: cm1,
            colorMatrix2: cm2,
            forwardMatrix1: fm1,
            forwardMatrix2: fm2,
            toneCurve: toneCurve
        )
    }
    
    private func readString(data: Data, count: Int, valOrOffset: Int) -> String? {
        let strOffset = count <= 4 ? 0 : valOrOffset
        guard strOffset + count <= data.count else { return nil }
        let sub = data.subdata(in: strOffset..<strOffset+count)
        return String(data: sub, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(["\0", " ", "\n", "\r"]))
    }
    
    private func readMatrix(data: Data, offset: Int, isLittleEndian: Bool) -> [Double]? {
        guard offset + 72 <= data.count else { return nil }
        var vals: [Double] = []
        var cur = offset
        for _ in 0..<9 {
            let num: Int32 = isLittleEndian ?
                data.subdata(in: cur..<cur+4).withUnsafeBytes { $0.load(as: Int32.self) } :
                Int32(bigEndian: data.subdata(in: cur..<cur+4).withUnsafeBytes { $0.load(as: Int32.self) })
            let den: Int32 = isLittleEndian ?
                data.subdata(in: cur+4..<cur+8).withUnsafeBytes { $0.load(as: Int32.self) } :
                Int32(bigEndian: data.subdata(in: cur+4..<cur+8).withUnsafeBytes { $0.load(as: Int32.self) })
            cur += 8
            if den != 0 {
                vals.append(Double(num) / Double(den))
            } else {
                vals.append(Double(num))
            }
        }
        return vals.count == 9 ? vals : nil
    }
    
    private func readToneCurve(data: Data, count: Int, offset: Int, isLittleEndian: Bool) -> [CGPoint]? {
        let numPoints = count / 2
        guard offset + (count * 4) <= data.count else { return nil }
        var points: [CGPoint] = []
        var cur = offset
        for _ in 0..<numPoints {
            let xBits: UInt32 = isLittleEndian ?
                data.subdata(in: cur..<cur+4).withUnsafeBytes { $0.load(as: UInt32.self) } :
                UInt32(bigEndian: data.subdata(in: cur..<cur+4).withUnsafeBytes { $0.load(as: UInt32.self) })
            let yBits: UInt32 = isLittleEndian ?
                data.subdata(in: cur+4..<cur+8).withUnsafeBytes { $0.load(as: UInt32.self) } :
                UInt32(bigEndian: data.subdata(in: cur+4..<cur+8).withUnsafeBytes { $0.load(as: UInt32.self) })
            cur += 8
            let x = Float(bitPattern: xBits)
            let y = Float(bitPattern: yBits)
            points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }
        return points
    }
}
