import SwiftUI

/// Formatted EXIF and Camera information display
public struct EXIFInfoView: View {
    public let asset: PhotoAsset
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            exifRow(label: "File Name", value: asset.filename)
            exifRow(label: "Format", value: "\(asset.fileExtension.uppercased()) \(asset.isRaw ? "(RAW Sensor)" : "")")
            exifRow(label: "File Size", value: ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
            
            if let w = asset.cameraMetadata.pixelWidth, let h = asset.cameraMetadata.pixelHeight {
                let mp = Double(w * h) / 1_000_000.0
                exifRow(label: "Dimensions", value: "\(w) × \(h) (\(String(format: "%.1f MP", mp)))")
            }
            
            Divider().background(LightroomTheme.dividerColor).padding(.vertical, 2)
            
            if let camera = asset.cameraMetadata.model {
                exifRow(label: "Camera", value: camera)
            }
            
            if let lens = asset.cameraMetadata.lensModel {
                exifRow(label: "Lens", value: lens)
            }
            
            if let focalStr = formattedFocalLength {
                exifRow(label: "Focal Length", value: focalStr)
            }
            
            if let exp = asset.cameraMetadata.shutterSpeed {
                exifRow(label: "Exposure", value: exp)
            }
            
            if let f = asset.cameraMetadata.aperture {
                exifRow(label: "Aperture", value: String(format: "ƒ/%.1f", f))
            }
            
            if let iso = asset.cameraMetadata.iso {
                exifRow(label: "ISO", value: "\(iso)")
            }
            
            if let expBias = asset.cameraMetadata.exposureCompensation {
                exifRow(label: "Exp Bias", value: String(format: "%+.1f EV", expBias))
            }
            
            if let wb = asset.cameraMetadata.whiteBalance {
                exifRow(label: "White Balance", value: wb)
            }
            
            if let dateStr = formattedCaptureDate {
                exifRow(label: "Captured", value: dateStr)
            }
            
            if asset.hasSidecarXMP {
                exifRow(label: "Sidecar XMP", value: "Present (.xmp)")
            }
        }
        .padding(.horizontal, 10)
    }
    
    private var formattedFocalLength: String? {
        guard let focal = asset.cameraMetadata.focalLength else { return nil }
        var str = String(format: "%.0f mm", focal)
        if let eq35 = asset.cameraMetadata.focalLength35mm, eq35 != focal {
            str += " (35mm eq: \(String(format: "%.0f mm", eq35)))"
        }
        return str
    }
    
    private var formattedCaptureDate: String? {
        guard let date = asset.cameraMetadata.captureDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func exifRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(LightroomTheme.textMuted)
                .frame(width: 85, alignment: .leading)
            
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(LightroomTheme.textPrimary)
                .lineLimit(2)
            
            Spacer()
        }
    }
}
